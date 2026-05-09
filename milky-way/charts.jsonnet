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

    // Based on https://github.com/democratic-csi/charts/blob/79a3c02588dfce133fcc3a1dfcdf7f15414fced8/stable/democratic-csi/examples/zfs-generic-iscsi.yaml
    values: {
      csiDriver: {
        # should be globally unique for a given cluster
        name: "org.democratic-csi.iscsi",
      },
      storageClasses: [
        {
          name: "my-custom-zfs-generic-iscsi",
          defaultClass: false,
          reclaimPolicy: "Retain",
          volumeBindingMode: "Immediate",
          allowVolumeExpansion: true,
          parameters: {
            fsType: "ext4",
          },
        },
      ],
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