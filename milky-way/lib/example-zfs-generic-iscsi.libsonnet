local utils = import 'milky-way/environments/default/utils.jsonnet';
local defaultAppName = "iscsi-test";
{
  new(
    storageClassName,
    name=defaultAppName,
    namespace="test-k8s",
  ):: {
    local this = self,

    statefulset: {
      apiVersion: "apps/v1",
      kind: "StatefulSet",

      metadata: {
        name: name,
        namespace: namespace,
      },

      spec: {
        serviceName: name,
        replicas: 1,

        selector: {
          matchLabels: {
            app: name,
          },
        },

        template: {
          metadata: {
            labels: {} + this.statefulset.spec.selector.matchLabels,
          },
          spec: {
            containers: [
              {
                name: "writer",
                image: "busybox:1.36",
                command: [
                  "sh",
                  "-c",
                  |||
                    set -eux

                    while true; do
                      date >> /data/out.txt
                      sync
                      sleep 5
                    done
                  |||,
                ],

                volumeMounts: [
                  {
                    name: utils.assertEqualAndReturn(this.statefulset.spec.volumeClaimTemplates[0].metadata.name, "storage"),
                    mountPath: "/data",
                  },
                ],
              },
            ],
          },
        },

        volumeClaimTemplates: [
          {
            metadata: {
              name: "storage",
            },
            spec: {
              accessModes: [
                "ReadWriteOncePod",
              ],
              storageClassName: storageClassName,
              resources: {
                requests: {
                  storage: "1Gi",
                },
              },
            },
          },
        ],
      },
    },

    service: {
      apiVersion: "v1",
      kind: "Service",
      metadata: {
        name: name,
        namespace: namespace,
      },
      spec: {
        clusterIP: "None",
        selector: this.statefulset.spec.template.metadata.labels,
      },
    },
  },
}