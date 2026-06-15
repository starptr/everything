local utils = import "milky-way/lib/utils.libsonnet";
local images = import "milky-way/lib/images.libsonnet";
{
  new(
    name="http-echo",
    image=images["http-echo"].fullyQualifiedImageReferenceTagged,
    port=5678,
  ):: {
    local this = self,

    deployment: {
      apiVersion: "apps/v1",
      kind: "Deployment",
      metadata: {
        namespace: "test-k8s",
        name: name,
      },
      spec: {
        replicas: 2,
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
              name: name,
              image: image,
              args: [
                "-listen=:%s" % port,
              ],
              ports: [{
                name: "main-http",
                containerPort: port,
              }],
            }],
          },
        },
      },
    },
    service: {
      apiVersion: "v1",
      kind: "Service",
      metadata: {
        namespace: "test-k8s",
        name: name,
      },
      spec: {
        selector: {} + this.deployment.spec.template.metadata.labels,
        ports: [{
          port: 80,
          targetPort: utils.assertEqualAndReturn(this.deployment.spec.template.spec.containers[0].ports[0].name, "main-http"),
        }],
        type: "ClusterIP",
      },
    },
    ingress: {
      apiVersion: "networking.k8s.io/v1",
      kind: "Ingress",
      metadata: {
        name: name,
        namespace: "test-k8s",
      },
      spec: {
        ingressClassName: "traefik",
        rules: [
          {
            http: {
              paths: [
                {
                  path: "/",
                  pathType: "Prefix",
                  backend: {
                    service: {
                      name: this.service.metadata.name,
                      port:{
                        number: utils.assertEqualAndReturn(this.service.spec.ports[0].port, 80),
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
  },
}