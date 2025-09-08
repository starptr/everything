local utils = import 'utils.jsonnet';
{
  /**
   * Some assumptions:
   * - Each call to new() creates an instance on a single node.
   * - Therefore, there must only be 1 replica.
   */
  new(
    nodeName,
    hostPathConfig,
    extraVolumes=[],
    extraVolumeMounts=[],
    name='syncthing',
    image='linuxserver/syncthing:latest',
  ):: {
    local this = self,
    local containerPortNames = {
      gui: 'gui',
      syncTcp: 'sync-tcp',
      syncUdp: 'sync-udp',
      discoveryUdpBroadcast: 'disco',
    },
    statefulset: {
      apiVersion: 'apps/v1',
      kind: 'StatefulSet',
      metadata: {
        name: name,
        labels: {
          app: name,
        },
      },
      spec: {
        serviceName: this.service.metadata.name,
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
            tolerations: [
              {
                key: "ephemeral",
                operator: "Exists",
                effect: "NoSchedule",
              }
            ],
            nodeSelector: {
              "kubernetes.io/hostname": nodeName,
            },
            containers: [
              {
                name: name,
                image: image,
                ports: [
                  { containerPort: 8384, name: containerPortNames.gui },
                  { containerPort: 22000, name: containerPortNames.syncTcp },
                  { containerPort: 22000, name: containerPortNames.syncUdp, protocol: 'UDP' },
                  { containerPort: 21027, name: containerPortNames.discoveryUdpBroadcast, protocol: 'UDP' },
                ],
                volumeMounts: [
                  {
                    name: utils.assertEqualAndReturn(this.statefulset.spec.volumeClaimTemplates[0].metadata.name, "syncthing-config"), // TODO: expected param should be passed in as a parameter to top-level new()
                    mountPath: '/config',
                  },
                ] + extraVolumeMounts,
                env: [
                  { name: 'PUID', value: '1000' },
                  { name: 'PGID', value: '1000' },
                  { name: 'TZ', value: 'UTC' },
                ],
              },
            ],
            volumes: [
              {
                name: "%s-config" % name,
                hostPath: {
                  path: hostPathConfig,
                  type: "Directory",
                },
              },
            ] + extraVolumes,
          },
        },
      },
    },

    service: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: {
        name: name,
        labels: {
          app: name,
        }
      },
      spec: {
        clusterIP: 'None',  // This is a headless service for the StatefulSet
        selector: this.statefulset.spec.selector.matchLabels,
        ports: [
          { port: 8384, targetPort: containerPortNames.gui, name: 'gui' },
          { port: 22000, targetPort: containerPortNames.syncTcp, name: 'sync-tcp' },
          { port: 22000, targetPort: containerPortNames.syncUdp, protocol: 'UDP', name: 'sync-udp' },
          { port: 21027, targetPort: containerPortNames.discoveryUdpBroadcast, protocol: 'UDP', name: 'disco' },
        ],
      },
    },

    ingress: {
      apiVersion: "networking.k8s.io/v1",
      kind: "Ingress",
      metadata: {
        name: name,
        annotations: {
          "kubernetes.io/ingress.class": "traefik",
          "traefik.ingress.kubernetes.io/router.entrypoints": "web",
          "traefik.ingress.kubernetes.io/router.tls": "false",
        },
      },
      spec: {
        rules: [
          {
            host: "syncthing.sdts.local",
            http: {
              paths: [
                {
                  path: "/",
                  pathType: "Prefix",
                  backend: {
                    service: {
                      name: name,
                      port: {
                        number: utils.assertEqualAndReturn(this.service.spec.ports[0].port, 8384), // TODO: verify name is 'gui' (actually, service should use ingress value)
                      },
                    },
                  },
                },
              ],
            },
          },
        ],
      },
    },

    resources:: [
      this.statefulset,
      this.service,
      this.ingress,
    ],
  },
}
