# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:

let
  publicKeys = (import ../../../magic/common/constants.nix { inherit lib; }).publicKeys;
in
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configurations/methanol.nix
      ./use-avahi-aliases.nix
    ];

  environment.systemPackages = [
    pkgs.rclone
    pkgs.vim
    pkgs.chaseln
    pkgs.htop
    pkgs.dig
    pkgs.ghostty.terminfo
    pkgs.lsof
    pkgs.nfs-utils # K8s node requirement for democratic-csi
    pkgs.e2fsprogs # Needed for allowVolumeExpansion (unverified; see https://chatgpt.com/share/6a0a3eba-c328-83e8-8a98-03f3cb85006e)
    pkgs.nfs-utils
    pkgs.targetcli-fb
  ];

  nix = {
    settings.experimental-features = [ "nix-command" "flakes" ];
  };

  # Use the systemd-boot EFI boot loader.
  #boot.loader.systemd-boot.enable = true;
  # Whether installer can modify the EFI variables. If you encounter errors, set this to `false`.
  boot.loader.efi.canTouchEfiVariables = true;

  boot.zfs.forceImportRoot = false;

  # Use grub boot loader to use the mirroring feature.
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    device = "nodev";
    copyKernels = true;
    mirroredBoots = [
      { devices = [ "/dev/disk/by-uuid/2700-2A8D" ]; path = "/boot"; }
      { devices = [ "/dev/disk/by-uuid/2733-1BD6" ]; path = "/boot2"; }
      { devices = [ "/dev/disk/by-uuid/275C-6335" ]; path = "/boot3"; }
      { devices = [ "/dev/disk/by-uuid/278C-829E" ]; path = "/boot4"; }
    ];
  };
  # ZFS configuration
  boot.supportedFilesystems = [ "zfs" ];

  # Allow booting if one boot filesystem fails
  fileSystems = {
    "/boot" = {
      options = [ "nofail" ];
    };
    "/boot2" = {
      options = [ "nofail" ];
    };
    "/boot3" = {
      options = [ "nofail" ];
    };
    "/boot4" = {
      options = [ "nofail" ];
    };
  };

  services.zfs = {
    autoScrub.enable = true;       # Weekly integrity checks
    autoSnapshot.enable = false;   # Replaced by services.sanoid below.
                                   # (Was a no-op anyway: zfs-auto-snapshot only
                                   # acts on datasets with com.sun:auto-snapshot=true,
                                   # which nothing here sets.)
    trim.enable = true;            # If using SSDs
  };

  # Zero-cost (copy-on-write, in-pool) snapshots of the democratic-csi k8s
  # volumes under rpool, for accidental-deletion / app-corruption rollback.
  #
  # Each PVC is a child of one of the two parents below (a zvol for iSCSI, a
  # dataset for NFS), named pvc-<uuid>. democratic-csi stamps each child with
  # ZFS user properties recording its origin (k8s:pvc-namespace, k8s:pvc-name,
  # k8s:pvc-ns-name). Those properties are inherently preserved on every
  # snapshot: a snapshot can't outlive its dataset, so for any snapshot that
  # exists the live dataset + properties exist too, and
  #   zfs get k8s:pvc-ns-name <dataset>@<snap>
  # always identifies the originating PVC. No metadata sidecar needed.
  #
  # recursive + processChildrenOnly: sanoid re-enumerates children on every run,
  # so dynamically-provisioned pvc-* volumes are auto-covered, and the empty
  # parent containers are skipped.
  #
  # These snapshots are CRASH-CONSISTENT, not application-consistent (apps keep
  # running during the snapshot). Each snapshot is tagged at creation time with a
  # local backup:consistency=crash-consistent property by the post_snapshot_script
  # below, so a restorer knows what they're getting. sanoid runs as a sandboxed
  # DynamicUser, so the service is additionally granted `userprop` delegation
  # (just below the block) to let that hook set the property.
  services.sanoid = {
    enable = true;

    templates.k8s-pvc = {
      autosnap = true;   # take snapshots
      autoprune = true;  # prune per the retention counts below
      hourly = 24;
      daily = 14;
      weekly = 4;
      monthly = 3;
      yearly = 0;

      # Tag each freshly-created snapshot crash-consistent at creation time
      # (local property, source=local — NOT an inherited default). sanoid runs
      # this immediately after taking the snapshot(s) for a dataset: SANOID_TARGETS
      # are the dataset(s) and SANOID_SNAPNAMES the new snapshot names. Iterating
      # the cross product with `|| true` is robust whether sanoid invokes the hook
      # per-child or batched. Requires the `userprop` delegation on the service
      # below; absolute zfs path because the DynamicUser has a minimal PATH.
      post_snapshot_script = "${pkgs.writeShellScript "sanoid-tag-crash-consistent" ''
        set -eu
        IFS=','
        for tgt in $SANOID_TARGETS; do
          for snap in $SANOID_SNAPNAMES; do
            /run/booted-system/sw/bin/zfs set \
              backup:consistency=crash-consistent "$tgt@$snap" || true
          done
        done
      ''}";
    };

    datasets."rpool/k8s/democratic-csi/my-zfs-generic-iscsi" = {
      useTemplate = [ "k8s-pvc" ];
      recursive = true;
      processChildrenOnly = true;
    };
    datasets."rpool/k8s/democratic-csi/my-zfs-nfs" = {
      useTemplate = [ "k8s-pvc" ];
      recursive = true;
      processChildrenOnly = true;
    };
  };

  # Grant the sanoid DynamicUser permission to set user properties on the two
  # democratic-csi parents (inherited by the per-PVC children) so its
  # post_snapshot_script can stamp backup:consistency on each snapshot. These
  # lists concatenate with the module's own snapshot,mount,destroy allow/unallow
  # (NixOS unitOption merge concatenates list-valued definitions). The `-+`
  # prefix means ignore-failure (tolerates a not-yet-created iSCSI parent) and
  # run as root. Revoked again when the service stops.
  systemd.services.sanoid.serviceConfig = {
    ExecStartPre = [
      "-+/run/booted-system/sw/bin/zfs allow sanoid userprop rpool/k8s/democratic-csi/my-zfs-generic-iscsi"
      "-+/run/booted-system/sw/bin/zfs allow sanoid userprop rpool/k8s/democratic-csi/my-zfs-nfs"
    ];
    ExecStopPost = [
      "-+/run/booted-system/sw/bin/zfs unallow sanoid userprop rpool/k8s/democratic-csi/my-zfs-generic-iscsi"
      "-+/run/booted-system/sw/bin/zfs unallow sanoid userprop rpool/k8s/democratic-csi/my-zfs-nfs"
    ];
  };

  # Required: set a unique hostId for ZFS
  networking.hostId = "7ebc8a61";

  networking.hostName = "methanol"; # Define your hostname.

  # Configure network connections interactively with nmcli or nmtui.
  networking.networkmanager.enable = true;

  # Run mDNS responder
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    allowInterfaces = [ "enp42s0" ]; # Restrict to physical interface to avoid K8s network interference
    publish = {
      enable = true;
      domain = true;
      addresses = true; # Publish hostname via mDNS
      userServices = true; # Allow avahi-publish to work via D-Bus
    };
  };

  # Avahi host aliases for LAN IP
  # Uses avahi-publish-address for proper local address alias publishing
  services.avahi-aliases = {
    enable = true;
    device = "enp42s0";
    aliases = [ "cwa-methanol.local" "mdata-methanol.local" ];
  };

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
  };

  services.k3s = {
    enable = true;
    role = "server";
    clusterInit = false;
    extraFlags = [
      "--flannel-backend=none"
      "--disable-network-policy"
      "--disable-kube-proxy"
    ];
  };

  # kata-containers (QEMU) microVM runtime for pods.
  # Make the kata shim + runtime visible to k3s/containerd so the `kata`
  # containerd runtime (registered via the config-v3.toml.tmpl symlink below)
  # can launch microVMs. The kata RuntimeClass is defined in milky-way.
  systemd.services.k3s.path = [ pkgs.kata-runtime ];

  # Delegate gives k3s its own cgroup subtree so the kata shim can create the
  # VM sandbox cgroups. We deliberately do NOT set DeviceAllow: that would flip
  # the unit to a device allowlist (breaking kubelet's /dev/kmsg and democratic-
  # csi's iSCSI block devices). The default DevicePolicy=auto already grants the
  # k3s process tree (incl. the kata QEMU hypervisor) access to /dev/kvm.
  systemd.services.k3s.serviceConfig = {
    Delegate = "yes";
  };

  # nfs server for democratic-csi
  services.nfs = {
    server = {
      enable = true;
      statdPort = 4000;
      lockdPort = 4001;
      mountdPort = 4002;
    };
  };

  services.openiscsi = {
    enable = true;
    name = "iqn.2003-01.app.andref.node-initiator:methanol";
  };

  # iSCSI service for democratic-csi
  services.target = {
    enable = true;
  };
  # Disable saveconfig.json management by services.target (it creates an empty {} file that overwrites
  # dynamically created iSCSI targets on every boot)
  # This lets targetcli manage the file naturally for democratic-csi
  # TODO: backup /etc/target/saveconfig.json so that the correspondence between zfs and iSCSI targets is preserved
  environment.etc."target/saveconfig.json".enable = false;

  # Ensure the /etc/target directory still exists (normally created by the etc entry above)
  systemd.tmpfiles.rules = [
    "d /etc/target 0700 root root -"
    # Register the kata containerd runtime by extending k3s's v3 containerd
    # template. k3s reads config-v3.toml.tmpl and regenerates config.toml
    # (version 3) on (re)start; the symlink only adds the template and never
    # touches the generated config.toml. Parent dir is created by k3s.
    "L+ /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl - - - - ${./methanol-containerd-config-v3.toml.tmpl}"
  ];

  # Ensure ZFS parent datasets exist for democratic-csi NFS driver
  # The NFS driver requires mounted datasets (not mountpoint=none) so that chmod and sharenfs work
  systemd.services.democratic-csi-nfs-dataset = {
    description = "Create ZFS parent dataset for democratic-csi NFS";
    wantedBy = [ "multi-user.target" ];
    after = [ "zfs-import.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail

      zfs="${pkgs.zfs}/bin/zfs"
      nfs_dataset="rpool/k8s/democratic-csi/my-zfs-nfs"
      nfs_mountpoint="/export/my-zfs-nfs"
      snapshots_dataset="rpool/k8s/democratic-csi/my-zfs-nfs-snapshots"

      dataset_exists() {
        "$zfs" list "$1" >/dev/null 2>&1
      }

      get_mountpoint() {
        "$zfs" get -H -o value mountpoint "$1"
      }

      # Create NFS parent dataset with mountpoint
      if ! dataset_exists "$nfs_dataset"; then
        "$zfs" create -o mountpoint="$nfs_mountpoint" "$nfs_dataset"
      elif [ "$(get_mountpoint "$nfs_dataset")" = "none" ]; then
        # Fix inherited mountpoint=none from parent
        "$zfs" set mountpoint="$nfs_mountpoint" "$nfs_dataset"
      fi

      # Create snapshots dataset (no mountpoint needed)
      if ! dataset_exists "$snapshots_dataset"; then
        "$zfs" create -o mountpoint=none "$snapshots_dataset"
      fi
    '';
  };

  # Set your time zone.
  time.timeZone = "America/Los_Angeles";

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkb.options in tty.
  # };

  # Enable the X11 windowing system.
  services.xserver.enable = false;


  # Enable the GNOME Desktop Environment.
  services.displayManager.gdm.enable = false;
  services.desktopManager.gnome.enable = false;
  

  # Configure keymap in X11
  # services.xserver.xkb.layout = "us";
  # services.xserver.xkb.options = "eurosign:e,caps:escape";

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # services.pulseaudio.enable = true;
  # OR
  # services.pipewire = {
  #   enable = true;
  #   pulse.enable = true;
  # };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.libinput.enable = true;

  # User account to easily login as a non-root.
  users.users.debug = {
    isNormalUser = true;
    createHome = true;
    extraGroups = [ "wheel" ]; # Enable ‘sudo’ for the user.
    packages = with pkgs; [
      tree
    ];
    openssh.authorizedKeys.keys = [
      publicKeys.ssh.yutoSodium # Yuto's Sodium
      publicKeys.ssh.onePasswordMain # 1Password "ssh key - main"
    ];
  };
  users.users.root.openssh.authorizedKeys.keys = [
    publicKeys.ssh.yutoSodium # Yuto's Sodium
    publicKeys.ssh.onePasswordMain # 1Password "ssh key - main"
  ];

  users.users.democratic-csi = {
    isNormalUser = true;
    createHome = true;
    shell = pkgs.bash;
    group = "democratic-csi";
    extraGroups = [ "wheel" ]; # Required for zfs manipulation
    openssh.authorizedKeys.keys = [
      publicKeys.ssh.yutoSodium # Yuto's Sodium
    ];
  };
  users.groups.democratic-csi = { };

  # programs.firefox.enable = true;

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
  # environment.systemPackages = with pkgs; [
  #   vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
  #   wget
  # ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  #services.openssh.settings.PermitRootLogin = "yes";
  security.sudo.wheelNeedsPassword = false;

  # Trust Cilium pod-facing interfaces so pods can reach host services
  # (API server on 6443, etc.) without per-port allowlisting.
  # lxc+ matches all lxc* veth pairs connecting pod network namespaces.
  networking.firewall.trustedInterfaces = [ "cilium_host" "cilium_net" "lxc+" ];

  # Open ports in the firewall.
  networking.firewall.allowedTCPPorts = [
    80
    443
    111 # rpcbind
    2049 # nfs
    config.services.nfs.server.statdPort
    config.services.nfs.server.mountdPort
    config.services.nfs.server.lockdPort
    30022 # mdata-sftp NodePort (SFTP over .local; see milky-way lib/sftp.libsonnet)
    30023 # grand-central bastion NodePort (public SSH jump; router forwards WAN 30023 here; see milky-way lib/grand-central.libsonnet)
  ];
  networking.firewall.allowedUDPPorts = config.networking.firewall.allowedTCPPorts;
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.11"; # Did you read the comment?

}

