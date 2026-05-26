local zfsIscsiDriverConfig = import 'milky-way/environments/stage00/orion-system/my-custom-zfs-iscsi-democratic-csi-driver-config.jsonnet';
local zfsNfsDriverConfig = import 'milky-way/environments/stage00/orion-system/my-custom-zfs-nfs-democratic-csi-driver-config.jsonnet';
local charts = import 'milky-way/charts.jsonnet';
local httpEcho = import 'milky-way/lib/http-echo.libsonnet';
local exampleZfsGenericIscsi = import 'milky-way/lib/example-zfs-generic-iscsi.libsonnet';
local calibreWebAuto = import 'milky-way/lib/calibre-web-automated.libsonnet';
{
  local this = self,
  democraticCsiNamespace: {
    apiVersion: "v1",
    kind: "Namespace",
    metadata: {
      name: "democratic-csi",
    },
  },
  zfsIscsiDriver: charts.zfs_iscsi,
  zfsNfsDriver: charts.zfs_nfs,
  "my-custom-zfs-iscsi-democratic-csi-driver-config": {
    apiVersion: "v1",
    kind: "Secret",
    metadata: {
      name: "my-custom-zfs-iscsi-democratic-csi-driver-config",
      namespace: "democratic-csi",
    },
    type: "Opaque",
    data: {
      "driver-config-file.yaml": std.base64(std.manifestYamlDoc(zfsIscsiDriverConfig)),
    },
  },
  "my-custom-zfs-nfs-democratic-csi-driver-config": {
    apiVersion: "v1",
    kind: "Secret",
    metadata: {
      name: "my-custom-zfs-nfs-democratic-csi-driver-config",
      namespace: "democratic-csi",
    },
    type: "Opaque",
    data: {
      "driver-config-file.yaml": std.base64(std.manifestYamlDoc(zfsNfsDriverConfig)),
    },
  },
  testingNamespace: {
    apiVersion: "v1",
    kind: "Namespace",
    metadata: {
      name: "test-k8s",
    },
  },
  httpEcho: httpEcho.new(),
  exampleZfsGenericIscsi: exampleZfsGenericIscsi.new(storageClassName="my-custom-zfs-generic-iscsi"),
  // TODO: rename lib
  exampleZfsNfs: exampleZfsGenericIscsi.new(
    storageClassName="my-custom-zfs-generic-nfs-csi",
    name="nfs-test",
  ),
  calibreWebAuto: calibreWebAuto.new(),

  cilium: charts.cilium,

  traefikConfig: {
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