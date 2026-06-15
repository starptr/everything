local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// A minimal smoke test for the Tailscale operator's L7 Ingress path
// (`ingressClassName: tailscale`). It deploys a single whoami pod, a ClusterIP
// Service, and a tailscale Ingress so we can confirm the operator provisions a
// proxy device and serves the backend over HTTPS on the tailnet.
//
// This deliberately exercises ONLY the Ingress controller path -- it does not
// use the `tailscale.com/expose` Service annotation (that is the separate L4
// service-exposure mechanism).
{
  new(
    tailscaleHostname,  // required, unique tailnet-wide; becomes the tailnet device name; reachable at https://<hostname>.<tailnet>.ts.net
    name='test-ts-ingress',
    namespace='test-k8s',
    // whoami echoes the request + headers, making a successful proxy hop self-evident.
    image=images.whoami.fullyQualifiedImageReferencePinnedForTailscaleOperatorIngressTest,
  ):: {
    local this = self,

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
            containers: [{
              name: 'whoami',
              image: image,
              ports: [{
                name: 'main-http',
                containerPort: 80,
              }],
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
          targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, 'main-http'),
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
        annotations: {
          'tailscale.com/funnel': 'false',  // tailnet-only, no public funnel
        },
      },
      spec: {
        ingressClassName: 'tailscale',
        tls: [
          {
            hosts: [tailscaleHostname],
          },
        ],
        rules: [
          {
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
          },
        ],
      },
    },
  },
}
