local utils = import 'utils.jsonnet';

{
  local security = self,

  /**
   * Deploys a test page.
   */
  makeTestPage(
    name,
    html=('<h1>Test Page</h1><p>This is a test page called "%s".</p>' % name),
    image='nginx:alpine@sha256:ef2d3f4eb5b25536e64702c82ea11e9dde6e0d2f551072a590bb5fb15176f3a4',
  ):: {
    local this = self,
    deployment: {
      apiVersion: 'apps/v1',
      kind: 'Deployment',
      metadata: {
        name: 'nginx-for-testpage-%s' % name,
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
                key: "ephemeral",
                operator: "Exists",
                effect: "NoSchedule",
              },
            ],
            containers: [{
              name: 'nginx',
              image: image,
              ports: [{
                name: "main-http",
                containerPort: 80,
              }],
              volumeMounts: [{
                name: utils.assertEqualAndReturn(this.deployment.spec.template.spec.volumes[0].name, "html"),
                mountPath: '/usr/share/nginx/html',
              }],
            }],
            volumes: [{
              name: 'html',
              configMap: {
                name: utils.assertEqualAndReturn(this.configmap.metadata.name, 'testpage-%s-html' % name),
              },
            }],
          },
        },
      },
    },
    // ConfigMap for HTML content
    configmap: {
      apiVersion: 'v1',
      kind: 'ConfigMap',
      metadata: {
        name: 'testpage-%s-html' % name,
      },
      data: {
        'index.html': html,
      },
    },
    service: {
      apiVersion: 'v1',
      kind: 'Service',
      metadata: {
        name: 'testpage-%s' % name,
      },
      spec: {
        selector: {} + this.deployment.spec.template.metadata.labels,
        ports: [{
          port: 80,
          targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, "main-http"),
        }],
      },
    },
  },

  newTestPages(
    publicDomain,
    tailscaleDomain,
    whoamiDomain,
    whoamiTailscaleDomain,
    name='security2-testpages',
  ):: {
    local this = self,
    publicTestPage: security.makeTestPage(
      name='%s-public' % name,
      html=|||
        <h1>Public Test Page 2</h1>
        <p>This page is publicly accessible.</p>
      |||,
    ),
    publicIngress: {
      apiVersion: 'traefik.io/v1alpha1',
      kind: 'IngressRoute',
      metadata: { name: '%s-public' % name },
      spec: {
        entryPoints: ['web'],
        routes: [{
          match: 'Host(`%s`)' % publicDomain,
          kind: 'Rule',
          services: [{
            name: this.publicTestPage.service.metadata.name,
            port: utils.assertEqualAndReturn(this.publicTestPage.service.spec.ports[0].port, 80),
          }],
        }],
      },
    },

    tailscaleOnlyTestPage: security.makeTestPage(
      name='%s-tailscale-only' % name,
      html=|||
        <h1>Tailscale-Only Test Page</h1>
        <p>This page is only accessible via Tailscale.</p>
      |||,
    ),
    tailscaleOnlyIngress: {
      apiVersion: 'networking.k8s.io/v1',
      kind: 'Ingress',
      metadata: { name: '%s-tailscale-only' % name },
      spec: {
        ingressClassName: "tailscale",
        tls: [
          {
            hosts: [tailscaleDomain],
          },
        ],
        defaultBackend: {
          service: {
            name: this.tailscaleOnlyTestPage.service.metadata.name,
            port: {
              number: utils.assertEqualAndReturn(this.tailscaleOnlyTestPage.service.spec.ports[0].port, 80),
            },
          },
        },
      },
    },

    /**
     * Debug this setup itself by deploying a "whoami" service that tells how the pod sees requests that go through this setup.
     * This is useful because currently, requests go through multiple layers of proxies (IngressRoute -> Middleware -> Service -> Pod),
     * and it's not always clear how the source IP and other headers are preserved or modified.
     */
    whoami:
      local outer = name;
      local name = '%s-whoami' % outer;
      {
        local whoami = self,
        deployment:  {
          apiVersion: 'apps/v1',
          kind: 'Deployment',
          metadata: { name: name },
          spec: {
            replicas: 1,
            selector: { matchLabels: { app: name } },
            template: {
              metadata: { labels: {} + whoami.deployment.spec.selector.matchLabels },
              spec: {
                tolerations: [
                  {
                    key: "ephemeral",
                    operator: "Exists",
                    effect: "NoSchedule",
                  },
                ],
                containers: [{
                  name: 'web',
                  image: 'traefik/whoami@sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab',  // minimal whoami server
                  ports: [{ containerPort: 80 }],
                }],
              },
            },
          },
        },
        service: {
          apiVersion: 'v1',
          kind: 'Service',
          metadata: { name: name },
          spec: {
            selector: { app: name },
            ports: [{ port: 80, targetPort: whoami.deployment.spec.template.spec.containers[0].ports[0].containerPort }],
          },
        },
        annotatedService: {
          apiVersion: 'v1',
          kind: 'Service',
          metadata: {
            name: "%s-annotated" % name,
            annotations: {
              "tailscale.com/expose": "true",
            },
          },
          spec: {
            selector: { app: name },
            ports: [{ port: 80, targetPort: whoami.deployment.spec.template.spec.containers[0].ports[0].containerPort }],
          },
        },
        ingressRoute: {
          apiVersion: 'traefik.io/v1alpha1',
          kind: 'IngressRoute',
          metadata: { name: name },
          spec: {
            entryPoints: ['web'],
            routes:
              local baseRoute = {
                kind: 'Rule',
                services: [{
                  name: whoami.service.metadata.name,
                  port: utils.assertEqualAndReturn(whoami.service.spec.ports[0].port, 80),
                }],
              }; [
                baseRoute {
                  match: 'Host(`%s`)' % whoamiDomain,
                },
              ],
          },
        },
        ingress: {
          apiVersion: 'networking.k8s.io/v1',
          kind: 'Ingress',
          metadata: { name: name },
          spec: {
            ingressClassName: "tailscale",
            tls: [
              {
                hosts: [whoamiTailscaleDomain],
              },
            ],
            defaultBackend: {
              service: {
                name: whoami.service.metadata.name,
                port: {
                  number: utils.assertEqualAndReturn(whoami.service.spec.ports[0].port, 80),
                },
              },
            },
          },
        },
      },
  },
}