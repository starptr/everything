local utils = import "milky-way/lib/utils.libsonnet";
local runtimeClassName = "kata";
{
  new(
    name="kata-microvm-test",
    namespace="test-k8s",
    image="busybox:1.36",
  ):: {
    local this = self,

    // Cluster-scoped RuntimeClass that maps to the `kata` containerd runtime
    // registered on the node via methanol.nix's config-v3.toml.tmpl.
    runtimeClass: {
      apiVersion: "node.k8s.io/v1",
      kind: "RuntimeClass",
      metadata: {
        name: runtimeClassName,
      },
      handler: runtimeClassName,
    },

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
            // Route this pod through the kata microVM runtime. Assert the name
            // matches the RuntimeClass above so they can never drift apart.
            runtimeClassName: utils.assertEqualAndReturn(this.runtimeClass.metadata.name, runtimeClassName),
            tolerations: [
              {
                key: "ephemeral",
                operator: "Exists",
                effect: "NoSchedule",
              },
            ],
            containers: [
              {
                name: "probe",
                image: image,
                // Log the guest kernel once (differs from the NixOS host kernel
                // when running inside a kata VM), then idle so we can `kubectl
                // exec` in to verify VM isolation and Service networking.
                command: [
                  "sh",
                  "-c",
                  |||
                    set -eux
                    uname -a
                    while true; do sleep 3600; done
                  |||,
                ],
              },
            ],
          },
        },
      },
    },
  },
}
