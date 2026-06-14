{
  new(
    name="test-example-whale-image-digest",
    namespace="test-k8s",
    // Pull the exact image whale pushed, pinned by its manifest digest. The digest
    // file is written by `nix run ./flake-profiles/whale#whale-push-example` and
    // imported here via the vendor/exports -> ../../exports jpath symlink.
    image="docker.io/yuto7/example-image@"
          + std.trim(importstr "exports/whale/digests/example-image.txt"),
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
