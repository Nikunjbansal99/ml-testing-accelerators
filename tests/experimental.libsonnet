# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

local utils = import 'templates/utils.libsonnet';
local volumes = import 'templates/volumes.libsonnet';

{
  TpuVmBaseTest:: {
    local config = self,
    local cleanupHook = {
      preStop: {
        exec: {
          command: [
            'bash',
            '/scripts/cleanup.sh',
          ],
        },
      },
    },

    publisherImage: null,
    volumeMap+: {
      scripts: volumes.MemoryVolumeSpec {
        name: 'scripts',
        mountPath: '/scripts',
      },
    },

    accelerator+: {
      name+: "-1vm"
    },

    tpuSettings+: {
      local tpuSettings = self,

      softwareVersion: if config.accelerator.replicas == 1 then
        'v2-nightly'
      else
        'v2-nightly-pod',

      // Startup script in TPU VM metadata.
      tpuVmStartupScript: 'echo Running startup script',

      // Amount of time to sleep after TPU is READY.
      tpuVmCreateSleepSeconds: 180,

      // Additional arguments for test Docker container.
      tpuVmDockerArgs: '',
    },
    podTemplate+:: {
      spec+: {
        containerMap+:: {
          monitor: null,
          train+: {
            image: 'google/cloud-sdk',
            lifecycle: cleanupHook,
            envMap+:: {
              'KUBE_GOOGLE_CLOUD_TPU_ENDPOINTS': if config.accelerator.replicas == 1 then
                'local'
              else
                'tpu-$(POD_UID)',
            },
            resources+: {
              // HACK: replace standard Cloud TPU resource.
              limits: {
                ['tpu.googleapis.com/v%s' % config.accelerator.version]: config.accelerator.size,
              },
            },
          },
        },
        initContainerMap+:: {
          'create-tpu': {
            image: 'google/cloud-sdk',
            local tpuCreateSettings = {
              acceleratorName: std.escapeStringBash(config.accelerator.name),
              softwareVersion: std.escapeStringBash(config.tpuSettings.softwareVersion),
              startupScript: std.escapeStringBash(config.tpuSettings.tpuVmStartupScript),
              sleepTime: config.tpuSettings.tpuVmCreateSleepSeconds,
            },
            command: utils.scriptCommand(|||
              project=$(curl -sS "http://metadata.google.internal/computeMetadata/v1/project/project-id" -H "Metadata-Flavor: Google")
              zone=$(curl -sS "http://metadata.google.internal/computeMetadata/v1/instance/zone" -H "Metadata-Flavor: Google" | awk -F'/' '{print $4}')
              tpu_name=tpu-${POD_UID}
              ssh-keygen -t rsa -f /scripts/id_rsa -q -N ""

              echo "
              curl -X DELETE \
                -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" \
                https://tpu.googleapis.com/v2alpha1/projects/${project}/locations/${zone}/nodes/${tpu_name}
              " > /scripts/cleanup.sh

              curl -X POST \
                -H "Authorization: Bearer $(gcloud auth print-access-token)" \
                -H "Content-Type: application/json" \
                -d "{
                  accelerator_type: %(acceleratorName)s,
                  runtime_version: %(softwareVersion)s,
                  network_config: {enable_external_ips: true},
                  metadata: {
                    'ssh-keys': 'xl-ml-test:$(cat /scripts/id_rsa.pub)',
                    'startup-script': %(startupScript)s
                  }
                }" https://tpu.googleapis.com/v2alpha1/projects/${project}/locations/${zone}/nodes?node_id=${tpu_name}

              echo "Waiting for TPU Pod ${tpu_name} to become ready..."
              while [[ ${health:-NONE} != "READY" ]];
                do sleep 10 && \
                health=$(gcloud \
                  --project=${project} \
                  compute \
                  tpus \
                  describe \
                  ${tpu_name} \
                  --zone=${zone} \
                  --format="value(state)") && \
                echo "Waiting for ready TPU (current state ${health:-NONE})...";
              done

              echo ${tpu_name} > /scripts/tpu_name
              gcloud compute tpus describe ${tpu_name} --project=${project} --zone=${zone} --format="value(ipAddress)" > /scripts/tpu_ip

              sleep %(sleepTime)d
            ||| % tpuCreateSettings),
            env: [
              {
                name: 'POD_UID',
                valueFrom: {
                  fieldRef: {
                    fieldPath: 'metadata.uid',
                  },
                },
              },
            ],
            volumeMounts: [
              {
                mountPath: '/scripts',
                name: 'scripts',
              },
            ],
          },
        },
      },
    },
  },
  TpuVmTrainingTest:: self.TpuVmBaseTest {
    local config = self,
    tpuSettings+: {
      tpuVmStartupScript: 'gcloud auth configure-docker && docker pull %(image)s' % config,
      tpuVmDockerArgs: if config.accelerator.replicas == 1 then
        ''
      else
        '--net host -e TPU_LOAD_LIBRARY=false',
    },
    podTemplate+:: {
      spec+: {
        containerMap+:: {
          monitor: null,
          train+: {
            envMap+:: {
              'LOCAL_OUTPUT_DIR': '/tmp/model_dir',
            },

            local remoteScript = {
              dockerImage: config.image,
              dockerArgs: config.tpuSettings.tpuVmDockerArgs,
              dockerCommand: std.escapeStringBash(
                std.join(
                  ' ',
                  config.command,
                ),
              ),
            },
            command: [
              'bash',
              '-c',
              |||
                set -x
                set -u
                ssh -i scripts/id_rsa -o StrictHostKeyChecking=no xl-ml-test@$(cat /scripts/tpu_ip) \
                  'sudo gcsfuse --implicit-dirs -o allow_other /gcs'
                ssh -i scripts/id_rsa -o StrictHostKeyChecking=no xl-ml-test@$(cat /scripts/tpu_ip) \
                  'sudo docker run -i --rm --privileged -v "/lib/libtpu.so:/lib/libtpu.so" -v "/gcs:/gcs" -v "$(LOCAL_OUTPUT_DIR):$(LOCAL_OUTPUT_DIR)" --entrypoint "" %(dockerArgs)s %(dockerImage)s '%(dockerCommand)s
                exit_code=$?
                ssh -i scripts/id_rsa -o StrictHostKeyChecking=no xl-ml-test@$(cat /scripts/tpu_ip) 'gsutil -m cp -r $(LOCAL_OUTPUT_DIR) $(MODEL_DIR)'
                bash /scripts/cleanup.sh
                exit $exit_code
              ||| % remoteScript,
            ],
          }
        }
      }
    }
  },
  TensorFlowTpuVmTest:: self.TpuVmTrainingTest {
    image: 'gcr.io/xl-ml-test/tensorflow-1vm:nightly',
  },
  TensorflowServingTpuVmTest:: self.TpuVmBaseTest {
    local config = self,
    image: 'gcr.io/xl-ml-test/allencwang-tf-serving-tpu:latest',

    tpuSettings+: {
      tpuVmStartupScript: 'gcloud auth configure-docker && ' +
        'git clone --depth=1 https://github.com/tensorflow/serving.git /serving/ && ' +
        'docker run -d --privileged -e MODEL_NAME=half_plus_two -e TPU_MIN_LOG_LEVEL=0 -p 8501:8501 -v "/serving/tensorflow_serving/servables/tensorflow/testdata/saved_model_half_plus_two_cpu:/models/half_plus_two" %(image)s' % config,
      tpuVmCreateSleepSeconds: 360,
    },

    podTemplate+: {
      spec+: {
        containerMap+:: {
          train+: {
            local scriptSettings = {
              testCommand:
                std.join(
                  ' ',
                  config.command,
                ),
            },
            command: [
              'bash',
              '-c',
              |||
                set -x
                set -u

                %(testCommand)s
                exit_code=$?
                bash /scripts/cleanup.sh
                exit $exit_code
              ||| % scriptSettings,
            ],
          },
        },
      },
    },
  },
}