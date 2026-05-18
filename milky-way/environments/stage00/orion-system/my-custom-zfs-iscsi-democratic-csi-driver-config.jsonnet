// Defined via sops-nix, updated via nixos-rebuild/darwin-rebuild.
local secrets = import 'milky-way/secrets/secrets-for-zfs-iscsi-driver.jsonnet';

// Based on https://github.com/democratic-csi/democratic-csi/blob/3974268272a84e9c22c47cae2fca847a8d422bad/examples/zfs-generic-iscsi.yaml
{
    "driver": "zfs-generic-iscsi",
    "sshConnection": {
        // IP of storage server to run zfs commands in.
	    // IP should be valid for k3s nodes to access the physical machine in,
	    // ie. local physical home network IP.
        "host": secrets.storageServerSsh.host,
        "port": secrets.storageServerSsh.port,
        "username": secrets.storageServerSsh.username,
        "password": secrets.storageServerSsh.password,
	    // TODO: use key
        //"privateKey": "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----\n"
    },
    "zfs": {
        cli: {
          sudoEnabled: true,
          paths: {
            // Storage server's binary paths
            zfs: "/run/current-system/sw/bin/zfs",
            zpool: "/run/current-system/sw/bin/zpool",
            sudo: "/run/wrappers/bin/sudo",
            chroot: "/run/current-system/sw/bin/chroot",
          },
        },
        "datasetParentName": "rpool/k8s/democratic-csi/my-zfs-generic-iscsi",
        "detachedSnapshotsDatasetParentName": "rpool/k8s/democratic-csi/my-zfs-generic-iscsi-snapshots",
        "zvolCompression": null,
        "zvolDedup": null,
        "zvolEnableReservation": false,
        "zvolBlocksize": null
    },
    "iscsi": {
        "shareStrategy": "targetCli",
        "shareStrategyTargetCli": {
          sudoEnabled: true,
            "basename": "iqn.2003-01.app.andref.d-csi",
            "tpg": {
                "attributes": {
                    "authentication": 0,
                    "generate_node_acls": 1,
                    "cache_dynamic_acls": 1,
                    "demo_mode_write_protect": 0
                },
                "auth": secrets.targetCliTpgAuth,
            },
            "block": {
                "attributes": {
                    "emulate_tpu": 0
                }
            }
        },
        // Verifiable via `sudo iscsiadm -m discovery -t sendtargets -p <ip>:<port>`
        "targetPortal": secrets.iscsiTargetPortal,
        "targetPortals": secrets.iscsiTargetPortals,
        "interface": "",
        "namePrefix": null,
        "nameSuffix": null
    }
}
