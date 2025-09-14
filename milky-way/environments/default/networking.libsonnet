{
  newTraefikSane():: {
    helmChartConfig: {
      apiVersion: 'helm.cattle.io/v1',
      kind: 'HelmChartConfig',
      metadata: {
        name: 'traefik',
        namespace: 'kube-system',
      },
      spec: {
        valuesContent: std.manifestYamlDoc({
          tolerations: [
            {
              key: "ephemeral",
              operator: "Exists",
              effect: "NoSchedule",
            },
            {
              key: "node-role.kubernetes.io/control-plane",
              operator: "Exists",
              effect: "NoSchedule",
            },
          ],
          ports: {
            web: {
              forwardedHeaders: {
                trustedIPs: [
                  "10.42.0.0/16"
                ],
              },
            },
          },
        }),
      },
    },
  },
}