local tanka = import "github.com/grafana/jsonnet-libs/tanka-util/main.libsonnet";
local helm = tanka.helm.new(std.thisFile);

{
  nginx: helm.template("ingress-nginx", "./charts/ingress-nginx", {
    namespace: "ingress-nginx",
    values: {
      persistence: { enabled: true },
      controller: {
        service: {
          type: "ClusterIP",
        },
        config: {
          allowSnippetAnnotations: true,
        },
        allowSnippetAnnotations: true,
      },
    },
  }),
  kubePrometheusStack: helm.template("kube-prometheus-stack", "./charts/kube-prometheus-stack", {
    namespace: "monitoring",
    values: {
      persistence: { enabled: true },
    },
  }),
  zfs_iscsi: helm.template("zfs-iscsi", "./charts/democratic-csi", {
    namespace: "democratic-csi",

    values: {
      driver: {
        // TODO: deploy secret via sops-nix which will symlink inside everything via magic
        existingConfigSecret: "my-custom-zfs-iscsi-democratic-csi-driver-config",
        config: {
          driver: "zfs-generic-iscsi",
        }
      }
    },
  }),
}