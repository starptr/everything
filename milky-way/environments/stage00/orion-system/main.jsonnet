local zfsIscsiDriverConfig = import 'milky-way/environments/stage00/orion-system/my-custom-zfs-iscsi-democratic-csi-driver-config.jsonnet';
local charts = import 'milky-way/charts.jsonnet';
local httpEcho = import 'milky-way/lib/http-echo.libsonnet';
local exampleZfsGenericIscsi = import 'milky-way/lib/example-zfs-generic-iscsi.libsonnet';
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
  testingNamespace: {
    apiVersion: "v1",
    kind: "Namespace",
    metadata: {
      name: "test-k8s",
    },
  },
  httpEcho: httpEcho.new(),
  exampleZfsGenericIscsi: exampleZfsGenericIscsi.new(storageClassName="my-custom-zfs-generic-iscsi"),
}