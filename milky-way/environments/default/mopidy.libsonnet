local digests = import 'digests.libsonnet';
local utils = import 'utils.jsonnet';
{
  new(
    name='mopidy',
    tailscaleServiceAnnotation=name,
    image=digests.mopidy
  ):: {
    local this = self,

    statefulSet: {
      apiVersion: "apps/v1",
      kind: "StatefulSet",
      metadata: {
        name: name,
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
            labels: {} + this.statefulSet.spec.selector.matchLabels,
          },
          spec: {
            containers: [{
              name: "mopidy",
              image: image,
              args: ["--config", "/etc/mopidy/mopidy.conf"],
              ports: [{
                containerPort: 6600,
                name: "mpd",
              }, {
                containerPort: 6680,
                name: "http",
              }],
              volumeMounts: [
                {
                  name: "mopidy-config",
                  mountPath: utils.assertEqualAndReturn(this.statefulSet.spec.template.spec.containers[0].args[1], "/etc/mopidy/mopidy.conf"),
                  subPath: "mopidy.conf",
                },
              ],
            }],
            volumes: [
              {
                name: "mopidy-config",
                secret: {
                  // Must be created separately beforehand
                  secretName: "mopidy-config",
                },
              },
            ],
          },
        },
      },
    },

    tailscaleService: {
      apiVersion: "v1",
      kind: "Service",
      metadata: {
        name: name,
        annotations: {
          "tailscale.com/expose": "true",
          "tailscale.com/hostname": tailscaleServiceAnnotation,
        },
      },
      spec: {
        selector: this.statefulSet.spec.selector.matchLabels,
        ports: [
          {
            port: 6600,
            targetPort: utils.assertEqualAndReturn(this.statefulSet.spec.template.spec.containers[0].ports[0].name, "mpd"),
            name: "mpd",
          },
          {
            port: 6680,
            targetPort: utils.assertEqualAndReturn(this.statefulSet.spec.template.spec.containers[0].ports[1].name, "http"),
            name: "http",
          },
        ],
      },
    },
  },
}