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
  // cert-manager issues the Let's Encrypt certs (ACME DNS-01 via Cloudflare). It owns issuance
  // cluster-wide and stores each cert in a Secret that every Traefik pod reads -- unlike Traefik's
  // file-based acme.json, this is safe once orion-system grows past a single node. crds.enabled
  // renders the (large) CRDs into this manifest set; the env applies them server-side (see
  // environments/stage00/orion-system/spec.json) so they don't hit the client-side annotation limit.
  certManager: helm.template("cert-manager", "./charts/cert-manager", {
    namespace: "cert-manager",
    values: {
      crds: { enabled: true },
      // startupapicheck is a Helm post-install HOOK Job; Tanka has no hook lifecycle, so it would be
      // applied as a plain Job that races the webhook. Skip it -- readiness is checked out-of-band.
      startupapicheck: { enabled: false },
    },
  }),
  cilium: helm.template("cilium", "./charts/cilium", {
    namespace: "kube-system",
    values: {
      operator: {
        replicas: 1,
      },
      kubeProxyReplacement: "true",
      k8sServiceHost: "127.0.0.1",
      k8sServicePort: 6443,
      // kata pods run their own guest kernel, so their connect()/sendmsg()
      // syscalls happen inside the VM and never hit the host-cgroup Socket LB
      // eBPF hook. Restrict Socket LB to the host namespace so pod traffic
      // (including kata VMs) falls back to the per-packet tc/eBPF LB at the
      // veth, letting kata pods reach Services and other pods like runc pods.
      // https://docs.cilium.io/en/stable/network/kubernetes/kata/
      socketLB: {
        hostNamespaceOnly: true,
      },
      ipam: {
        mode: "kubernetes",
      },
      clusterPoolIPv4PodCIDRList: ["10.42.0.0/16"],
      // Use the host's existing cgroup2 mount instead of creating a
      // separate one. NixOS mounts cgroup2 at /sys/fs/cgroup; Cilium's
      // default auto-mount creates a separate cgroup2 at /run/cilium/cgroupv2
      // which is NOT the hierarchy pods live in, breaking Socket LB.
      cgroup: {
        autoMount: { enabled: false },
        hostRoot: "/sys/fs/cgroup",
      },
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
      controller: {
        driver: {
          securityContext: {
            privileged: true,
          },
        },
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
            detachedVolumesFromSnapshots: false,
            detachedVolumesFromVolumes: false,
          },
        },
      ],
      volumeSnapshotClasses: [
        // TODO: install a snapshotter CRD
        //{
        //  name: "my-custom-zfs-generic-iscsi-snapshotter",
        //  deletionPolicy: "Retain",
        //  parameters: {
        //    detachedSnapshots: "false",
        //  },
        //},
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
  zfs_nfs: helm.template("my-zfs-nfs", "./charts/democratic-csi", {
    namespace: "democratic-csi",

    // Based on https://github.com/democratic-csi/charts/blob/79a3c02588dfce133fcc3a1dfcdf7f15414fced8/stable/democratic-csi/examples/zfs-generic-nfs.yaml
    values: {
      csiDriver: {
        # should be globally unique for a given cluster
        name: "org.democratic-csi.my-nfs",
        fsGroupPolicy: "File",
      },
      storageClasses: [
        {
          name: "my-custom-zfs-generic-nfs-csi",
          defaultClass: false,
          reclaimPolicy: "Retain",
          volumeBindingMode: "Immediate",
          allowVolumeExpansion: true,
          parameters: {
            # for block-based storage can be ext3, ext4, xfs
            # for nfs should be nfs
            fsType: "nfs",
          },
      
          # if true, volumes created from other snapshots will be
          # zfs send/received instead of zfs cloned
          detachedVolumesFromSnapshots: false,
      
          # if true, volumes created from other volumes will be
          # zfs send/received instead of zfs cloned
          detachedVolumesFromVolumes: false,
      
          mountOptions: [
            "noatime",
            "nfsvers=3",
          ],
        },
      ],
      
      # if your cluster supports snapshots you may enable below
      volumeSnapshotClasses: [],
      #- name: zfs-generic-nfs-csi
      #  parameters:
      #  # if true, snapshots will be created with zfs send/receive
      #  # detachedSnapshots: "false"
      #  secrets:
      #    snapshotter-secret:
      
      driver: {
        existingConfigSecret: "my-custom-zfs-nfs-democratic-csi-driver-config",
        config: {
          # please see the most up-to-date example of the corresponding config here:
          # https://github.com/democratic-csi/democratic-csi/tree/master/examples
          # YOU MUST COPY THE DATA HERE INLINE!
          driver: "zfs-generic-nfs",
        },
      },
    },
  }),
}