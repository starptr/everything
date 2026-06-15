local images = import 'milky-way/lib/images.libsonnet';
{
  new(
    name="test-example-whale-image-digest",
    namespace="test-k8s",
    // Pinned by manifest digest from exports/whale/digests/, via the shared images lib.
    image=images["example-image"].fullyQualifiedImageReferencePinned,
  ):: {
    local this = self,

    deployment: {
      apiVersion: "apps/v1",
      kind: "Deployment",
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
                key: "ephemeral",
                operator: "Exists",
                effect: "NoSchedule",
              },
            ],
            // No command/args override: the image's own Entrypoint+Cmd
            // (dumb-init -- sleep infinity) keeps the pod Running and makes it
            // terminate promptly on SIGTERM.
            containers: [
              {
                name: name,
                image: image,
              },
            ],
          },
        },
      },
    },
  },
}
