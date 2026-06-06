{
  // HelmChartConfig that reconfigures the k3s-bundled Traefik to bind directly to host
  // ports via hostNetwork, bypassing ServiceLB (klipper-lb) which is incompatible with
  // Cilium's BPF packet redirect.
  reconfigForCilium():: {
    apiVersion: "helm.cattle.io/v1",
    kind: "HelmChartConfig",
    metadata: {
      name: "traefik",
      namespace: "kube-system",
    },
    spec: {
      valuesContent: std.manifestYamlDoc({
        deployment: {
          kind: "DaemonSet",
        },
        // Bind directly to host ports — bypasses ServiceLB (klipper-lb)
        // which is incompatible with Cilium's BPF packet redirect.
        hostNetwork: true,
        updateStrategy: {
          rollingUpdate: {
            maxSurge: 0,
            maxUnavailable: 1,
          },
        },
        // Listen on standard ports directly (hostNetwork exposes these).
        ports: {
          web: { port: 80 },
          websecure: { port: 443 },
        },
        // Required for binding privileged ports (80, 443) with hostNetwork.
        securityContext: {
          capabilities: {
            add: ["NET_BIND_SERVICE"],
            drop: ["ALL"],
          },
          readOnlyRootFilesystem: true,
          runAsNonRoot: false,
          runAsUser: 0,
          runAsGroup: 0,
        },
        podSecurityContext: {
          runAsNonRoot: false,
          runAsUser: 0,
          runAsGroup: 0,
        },
        service: {
          // Keep ClusterIP for in-cluster traffic to Traefik;
          // external traffic arrives via host ports directly.
          type: "ClusterIP",
        },
        tolerations: [
          { key: "ephemeral", operator: "Exists", effect: "NoSchedule" },
        ],
      }),
    },
  },
}
