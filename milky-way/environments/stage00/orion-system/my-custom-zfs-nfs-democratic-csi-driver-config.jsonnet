// Defined via sops-nix, updated via nixos-rebuild/darwin-rebuild.
// TODO: rename the file
local secrets = import 'milky-way/secrets/secrets-for-zfs-iscsi-driver.jsonnet';
local myCustomZfsIscsiDriverConfig = import 'milky-way/environments/stage00/orion-system/my-custom-zfs-iscsi-democratic-csi-driver-config.jsonnet';

// Based on https://github.com/democratic-csi/democratic-csi/blob/3974268272a84e9c22c47cae2fca847a8d422bad/examples/zfs-generic-nfs.yaml
{
  driver: "zfs-generic-nfs",
  sshConnection: myCustomZfsIscsiDriverConfig.sshConnection,
  zfs: {
    cli: myCustomZfsIscsiDriverConfig.zfs.cli,

    datasetParentName: "rpool/k8s/democratic-csi/my-zfs-nfs",
    detachedSnapshotsDatasetParentName: "rpool/k8s/democratic-csi/my-zfs-nfs-snapshots",
    // Store PVC metadata in ZFS properties for easy identification
    datasetProperties: {
      "k8s:pvc-namespace": "{{ parameters.[csi.storage.k8s.io/pvc/namespace] }}",
      "k8s:pvc-name": "{{ parameters.[csi.storage.k8s.io/pvc/name] }}",
      "k8s:pvc-ns-name": "{{ parameters.[csi.storage.k8s.io/pvc/namespace] }}/{{ parameters.[csi.storage.k8s.io/pvc/name] }}"
    },
    datasetEnableQuotas: true,
    datasetEnableReservation: false,
    datasetPermissionsMode: "0777",
    datasetPermissionsUser: 0,
    datasetPermissionsGroup: 0,
  },
  nfs: {
    shareStrategy: "setDatasetProperties",
    shareStrategySetDatasetProperties: {
      properties: {
        sharenfs: "on",
      },
    },
    shareHost: secrets.nfsShareHost,
  },
}