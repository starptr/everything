local kataRuntimeClass = import "milky-way/lib/kata-runtime-class.libsonnet";
local images = import "milky-way/lib/images.libsonnet";
{
  new(
    name="kata-microvm-test",
    namespace="test-k8s",
    image=images.busybox.fullyQualifiedImageReferenceTaggedForKataMicrovmTest,
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
            // Route this pod through the kata microVM runtime (see
            // lib/kata-runtime-class.libsonnet for the RuntimeClass itself).
            runtimeClassName: kataRuntimeClass.name,
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
