// Cluster-scoped RuntimeClass mapping the `kata` handler to the kata-containers
// (QEMU) containerd runtime registered on the node via venus's methanol.nix
// (config-v3.toml.tmpl). Workloads opt in with `runtimeClassName: kata`.
local name = "kata";
{
  // Exposed so workloads set their runtimeClassName from one source of truth.
  name:: name,

  runtimeClass: {
    apiVersion: "node.k8s.io/v1",
    kind: "RuntimeClass",
    metadata: {
      name: name,
    },
    handler: name,
  },
}
