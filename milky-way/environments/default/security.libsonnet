local utils = import 'utils.libsonnet';
# Ensure that internal services are not exposed to the public internet
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

  middleware: {
    allowTailscaleName: 'allow-tailscale',
  },

  /**
   * Middleware that only allows access from Tailscale IPs
   */
  newTailscaleOnlyMiddleware():: {
    middleware: {
      apiVersion: 'traefik.containo.us/v1alpha1',
      kind: 'Middleware',
      metadata: {
        name: security.middleware.allowTailscaleName,
      },
      spec: {
        ipWhiteList: {
          sourceRange: ['100.64.0.0/10'],
        },
      },
    },
  },

  /**
   * Deploys 2 test pages: one that is publicly acessible, and one that is only accessible via Tailscale.
   * Requires the Tailscale-only middleware defined above.
   * In the future, this can be extended to deploy more test pages for other security scenarios.
   */
  newTestPages(
    publicDomain, // Domain for the public test page
    publicDomainForTailscalePage, // Domain for the Tailscale-only test page (should be inaccessible but have a DNS record)
    tailscaleDomain, // Domain for the Tailscale-only test page (should be accessible via Tailscale)
    name='security-testpages',
  ):: {
    local this = self,
    publicTestPage: security.makeTestPage(
      name='%s-public' % name,
      html=|||
        <h1>Public Test Page</h1>
        <p>This page is publicly accessible.</p>
      |||,
    ),
    publicIngress: {
      apiVersion: 'traefik.containo.us/v1alpha1',
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
      apiVersion: 'traefik.containo.us/v1alpha1',
      kind: 'IngressRoute',
      metadata: { name: '%s-tailscale-only' % name },
      spec: {
        entryPoints: ['web'],
        routes:
          local baseRoute = {
            kind: 'Rule',
            services: [{
              name: this.tailscaleOnlyTestPage.service.metadata.name,
              port: utils.assertEqualAndReturn(this.tailscaleOnlyTestPage.service.spec.ports[0].port, 80),
            }],
            middlewares: [{
              name: security.middleware.allowTailscaleName,
            }],
          }; [
          baseRoute {
            match: 'Host(`%s`)' % tailscaleDomain,
          },
          baseRoute {
            match: 'Host(`%s`)' % publicDomainForTailscalePage,
          },
        ],
      },
    },
  },
}