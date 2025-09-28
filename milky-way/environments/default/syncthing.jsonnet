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
    tailscaleServiceAnnotation=name,
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
                    // Ensure this name matches the volume name below
                    name: utils.assertEqualAndReturn(this.statefulset.spec.template.spec.volumes[0].name, "%s-config" % name),
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

    // I think this service is needed to expose syncthing to peers
    service: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: {
        name: name,
        labels: {
          app: name,
        },
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

    // Separate service to expose the webapp to tailscale
    webappService: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: {
        name: '%s-webapp-only' % name,
        annotations: {
          "tailscale.com/expose": "true",
          "tailscale.com/hostname": tailscaleServiceAnnotation,
        },
      },
      spec: {
        selector: this.statefulset.spec.selector.matchLabels,
        ports: [
          { port: 80, targetPort: containerPortNames.gui, name: 'gui' },
        ],
      },
    },

    //ingress: {
    //  apiVersion: "networking.k8s.io/v1",
    //  kind: "Ingress",
    //  metadata: {
    //    name: name,
    //    annotations: {
    //      "kubernetes.io/ingress.class": "traefik",
    //      "traefik.ingress.kubernetes.io/router.entrypoints": "web",
    //      "traefik.ingress.kubernetes.io/router.tls": "false",
    //    },
    //  },
    //  spec: {
    //    rules: [
    //      {
    //        host: "syncthing.sdts.local",
    //        http: {
    //          paths: [
    //            {
    //              path: "/",
    //              pathType: "Prefix",
    //              backend: {
    //                service: {
    //                  name: name,
    //                  port: {
    //                    number: utils.assertAndReturn(this.service.spec.ports[0], function(mapping)
    //                      mapping.name == 'gui',
    //                      message='Expected mapping for the "gui" port'
    //                    ).port,
    //                  },
    //                },
    //              },
    //            },
    //          ],
    //        },
    //      },
    //    ],
    //  },
    //},

    resources:: [
      this.statefulset,
      this.service,
      this.ingress,
    ],
  },
}
