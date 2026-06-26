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
          websecure: {
            port: 443,
            // Traefik v3 defaults respondingTimeouts.readTimeout to 60s, and that covers reading the
            // ENTIRE request body. So any HTTPS request whose body takes >60s to upload is aborted
            // mid-stream (observed: a slow POST is cut at exactly 60.1s) -- which kills every
            // multi-GB upload to andref-ipfs-depot, surfacing as a 502/Bad Gateway. Disable it (0s)
            // so long uploads can complete; this is entrypoint-wide, but the other websecure routes
            // (kubo gateway, etc.) serve GETs with tiny bodies, so it doesn't weaken them, and
            // idleTimeout (180s) still bounds genuinely idle connections. Upload SIZE is still
            // bounded by andref-ipfs-depot's own 8 GiB body limit.
            transport: { respondingTimeouts: { readTimeout: '0s' } },
          },
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
