local utils = import 'milky-way/lib/utils.libsonnet';
local defaultAppName = "calibre-web-auto";

{
  new(
    name=defaultAppName,
    namespace="default",
    image="docker.io/crocodilestick/calibre-web-automated:latest",
    timezone="UTC",
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
                name: name,
                image: image,
                ports: [
                  {
                    containerPort: // the port that the application listens on
                      local calibreWebAutoContainer = utils.assertAndReturn(
                        this.statefulset.spec.template.spec.containers[0],
                        function(container) container.name == name, # Ensure this is the main calibre-web-auto container
                      );
                      local portEnvVarStr = utils.assertAndReturn(
                        calibreWebAutoContainer.env[4],
                        function(var) var.name == "CWA_PORT_OVERRIDE", # Ensure this is the CWA_PORT_OVERRIDE env var
                      ).value;
                      std.parseInt(portEnvVarStr), # Parse the port number from the env var
                    name: "webui",
                  },
                ],
                env: [
                  { name: "PUID", value: "1000" },
                  { name: "PGID", value: "1000" },
                  { name: "TZ", value: timezone },
                  { name: "NETWORK_SHARE_MODE", value: "true" },
                  { name: "CWA_PORT_OVERRIDE", value: "8083" },
                ],
                volumeMounts: [
                  {
                    name: utils.assertEqualAndReturn(this.statefulset.spec.volumeClaimTemplates[0].metadata.name, "config"),
                    mountPath: "/config",
                  },
                  {
                    name: utils.assertEqualAndReturn(this.statefulset.spec.volumeClaimTemplates[1].metadata.name, "book-ingest"),
                    mountPath: "/cwa-book-ingest",
                  },
                  {
                    name: utils.assertEqualAndReturn(this.statefulset.spec.volumeClaimTemplates[2].metadata.name, "calibre-library"),
                    mountPath: "/calibre-library",
                  },
                ],
              },
            ],
          },
        },

        volumeClaimTemplates: [
          {
            metadata: {
              name: "config",
            },
            spec: {
              accessModes: ["ReadWriteOncePod"],
              storageClassName: "my-custom-zfs-generic-nfs-csi",
              resources: {
                requests: {
                  storage: "10Gi",
                },
              },
            },
          },
          {
            metadata: {
              name: "book-ingest",
            },
            spec: {
              accessModes: ["ReadWriteMany"],
              storageClassName: "my-custom-zfs-generic-nfs-csi",
              resources: {
                requests: {
                  storage: "10Gi",
                },
              },
            },
          },
          {
            metadata: {
              name: "calibre-library",
            },
            spec: {
              accessModes: ["ReadWriteMany"],
              storageClassName: "my-custom-zfs-generic-nfs-csi",
              resources: {
                requests: {
                  storage: "10Gi",
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
        ports: [
          {
            port: 80,
            targetPort:
              local calibreWebAutoContainer = utils.assertAndReturn(
                this.statefulset.spec.template.spec.containers[0],
                function(container) container.name == name,
              );
              utils.assertEqualAndReturn(calibreWebAutoContainer.ports[0].name, "webui"),
            name: "http",
          },
        ],
      },
    },
  },
}
