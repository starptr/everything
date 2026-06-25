local utils = import 'milky-way/lib/utils.libsonnet';
local images = import 'milky-way/lib/images.libsonnet';

// A smoke test for the Traefik + cert-manager wildcard-cert path. It deploys a single whoami pod, a
// ClusterIP Service, a cert-manager Certificate, and a traefik-class Ingress, so we can confirm that:
//   1. cert-manager obtains ONE Let's Encrypt cert (ACME DNS-01 / Cloudflare) covering both the apex
//      (<baseDomain>) and the wildcard (*.<baseDomain>), storing it in a TLS Secret; and
//   2. Traefik serves that Secret over HTTPS for both the apex host and a concrete wildcard subdomain.
//
// This is the cert-manager path, NOT Traefik's built-in ACME: the Certificate -> Secret is issued once
// cluster-wide and every Traefik pod reads it via the Ingress's spec.tls.secretName, which stays
// correct as orion-system grows past one node. See lib/letsencrypt-cloudflare.libsonnet for the issuers.
{
  new(
    baseDomain,             // e.g. 'test-traefik-acme.andref.app'; apex + '*.'+this are the cert SANs
    issuerName,             // ClusterIssuer to issue from (staging first, then prod)
    name='test-traefik-acme',
    namespace='test-k8s',
    // whoami echoes the request + headers, making a successful TLS proxy hop self-evident.
    image=images.whoami.fullyQualifiedImageReferencePinnedForTraefikAcmeTest,
  ):: {
    local this = self,
    local wildcardHost = '*.' + baseDomain,
    local subHost = 'whoami.' + baseDomain,   // a concrete subdomain that exercises the wildcard cert
    local tlsSecretName = name + '-wildcard-tls',

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

    // cert-manager obtains a single cert covering the apex and the wildcard, into tlsSecretName (same
    // namespace as the Ingress, so Traefik can read it). DNS-01 means no inbound reachability is needed
    // to issue; cert-manager creates/cleans the _acme-challenge.<baseDomain> TXT in Cloudflare itself.
    certificate: {
      apiVersion: 'cert-manager.io/v1',
      kind: 'Certificate',
      metadata: {
        name: name + '-wildcard',
        namespace: namespace,
      },
      spec: {
        secretName: tlsSecretName,
        dnsNames: [baseDomain, wildcardHost],
        issuerRef: {
          name: issuerName,
          kind: 'ClusterIssuer',
        },
      },
    },

    ingress: {
      apiVersion: 'networking.k8s.io/v1',
      kind: 'Ingress',
      metadata: {
        name: name,
        namespace: namespace,
        annotations: {
          // HTTPS only -- this test is about the cert, so bind the routers to the TLS entrypoint.
          'traefik.ingress.kubernetes.io/router.entrypoints': 'websecure',
        },
      },
      spec: {
        ingressClassName: 'traefik',
        // Traefik's Kubernetes Ingress provider loads the cert from this Secret and serves it on
        // websecure for the listed hosts. secretName is asserted equal to the Certificate's output.
        tls: [{
          hosts: [baseDomain, wildcardHost],
          secretName: utils.assertEqualAndReturn(tlsSecretName, this.certificate.spec.secretName),
        }],
        rules: [
          {
            // apex -> exercises the cert's main/apex SAN
            host: baseDomain,
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
          {
            // a concrete subdomain -> exercises the wildcard SAN
            host: subHost,
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
