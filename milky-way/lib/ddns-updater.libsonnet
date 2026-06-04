local utils = import 'milky-way/lib/utils.libsonnet';

{
  new(
    config,                       // ddns-updater config object, e.g. { settings: [...] }
    domain,                       // Ingress host for the web UI
    name='ddns-updater',
    namespace='default',
    image='qmcgaw/ddns-updater',
    port=8000,
  ):: {
    local this = self,

    secret: {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: {
        name: name,
        namespace: namespace,
      },
      type: 'Opaque',
      data: {
        'config.json': std.base64(std.manifestJsonEx(config, '  ')),
      },
    },

    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: {
        name: name,
        namespace: namespace,
      },
      spec: {
        replicas: 1,
        selector: {
          matchLabels: {
            app: name,
          },
        },
        template: {
          metadata: {
            labels: {} + this.deployment.spec.selector.matchLabels,
          },
          spec: {
            tolerations: [
              {
                key: 'ephemeral',
                operator: 'Exists',
                effect: 'NoSchedule',
              },
            ],
            containers: [
              {
                name: name,
                image: image,
                env: [
                  // Read the config from the mounted secret rather than the default
                  // /updater/data/config.json, leaving /updater/data writable for runtime
                  // state (updates.json).
                  { name: 'CONFIG_FILEPATH', value: '/secret/config.json' },
                  { name: 'LISTENING_ADDRESS', value: ':%s' % port },
                ],
                ports: [{
                  name: 'webui',
                  containerPort: port,
                }],
                volumeMounts: [{
                  name: utils.assertEqualAndReturn(this.deployment.spec.template.spec.volumes[0].name, 'config'),
                  mountPath: '/secret',
                  readOnly: true,
                }],
              },
            ],
            volumes: [{
              name: 'config',
              secret: {
                secretName: utils.assertEqualAndReturn(this.secret.metadata.name, name),
              },
            }],
          },
        },
      },
    },

    service: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: {
        name: name,
        namespace: namespace,
      },
      spec: {
        selector: {} + this.deployment.spec.template.metadata.labels,
        ports: [{
          port: 80,
          targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, 'webui'),
        }],
        type: 'ClusterIP',
      },
    },

    ingress: {
      apiVersion: 'networking.k8s.io/v1',
      kind: 'Ingress',
      metadata: {
        name: name,
        namespace: namespace,
      },
      spec: {
        ingressClassName: 'traefik',
        rules: [{
          host: domain,
          http: {
            paths: [{
              path: '/',
              pathType: 'Prefix',
              backend: {
                service: {
                  name: this.service.metadata.name,
                  port: {
                    number: utils.assertEqualAndReturn(this.service.spec.ports[0].port, 80),
                  },
                },
              },
            }],
          },
        }],
      },
    },
  },
}
