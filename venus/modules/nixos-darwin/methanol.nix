# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:

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
    autoSnapshot.enable = true;    # Automatic snapshots
    trim.enable = true;            # If using SSDs
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
    aliases = [ "cwa-methanol.local" ];
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
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDLrT2/gQXhOz4E4xSphB8EXouild5qNOnZ6ZVXuTnf167z8xxSB10mxNey2gKDaIVig6I/tRFeYy6/N/QutbBlKI/+GNPjGCcVJI0hf7fTZGL4caTW8ggcXRz4LAsFp3JBf6Li0FVrGz5ojD0Etbl54BDn033q/tlVRhme5bXJ6s73yRg04kqdQsWVBRJwyzbUUmCQPrZd9i5Nh4QFVuhZljEyUWIStajE+c9v8OOiY1svv+XjKBjyWphP16HqgzvnEDf5+MQ5AUxE05IvJx43UY43CKTe3evzt4F/IqSdYwYGIQ55DaseRmf5zmHLU8MTTkksmOPQEzJL0nBzAmxyGV3PsMYPoIN+1/gJmxCO6ZaaCxYr9SFK/yoRW5e0PFX433xPhNsITBq7jUrVg6BQ/lr0ntRfvd7pRhFq8v02R3jWokL/99skxp1kjVF42bXEJXYPpHF3XAUhYscjOwmWj8dJgsIsSIKIjh7gRVYxQGrZQXOcJQjMytFgXy7fWHM= yuto@Yutos-MacBook-Pro.local" # Yuto's Sodium
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPtVvX9uhSWD1DPBIRqgkNzFXqjdqvWB/WtDy4seaiJl" # 1Password "ssh key - main"
    ];
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDLrT2/gQXhOz4E4xSphB8EXouild5qNOnZ6ZVXuTnf167z8xxSB10mxNey2gKDaIVig6I/tRFeYy6/N/QutbBlKI/+GNPjGCcVJI0hf7fTZGL4caTW8ggcXRz4LAsFp3JBf6Li0FVrGz5ojD0Etbl54BDn033q/tlVRhme5bXJ6s73yRg04kqdQsWVBRJwyzbUUmCQPrZd9i5Nh4QFVuhZljEyUWIStajE+c9v8OOiY1svv+XjKBjyWphP16HqgzvnEDf5+MQ5AUxE05IvJx43UY43CKTe3evzt4F/IqSdYwYGIQ55DaseRmf5zmHLU8MTTkksmOPQEzJL0nBzAmxyGV3PsMYPoIN+1/gJmxCO6ZaaCxYr9SFK/yoRW5e0PFX433xPhNsITBq7jUrVg6BQ/lr0ntRfvd7pRhFq8v02R3jWokL/99skxp1kjVF42bXEJXYPpHF3XAUhYscjOwmWj8dJgsIsSIKIjh7gRVYxQGrZQXOcJQjMytFgXy7fWHM= yuto@Yutos-MacBook-Pro.local" # Yuto's Sodium
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPtVvX9uhSWD1DPBIRqgkNzFXqjdqvWB/WtDy4seaiJl" # 1Password "ssh key - main"
  ];

  users.users.democratic-csi = {
    isNormalUser = true;
    createHome = true;
    shell = pkgs.bash;
    group = "democratic-csi";
    extraGroups = [ "wheel" ]; # Required for zfs manipulation
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDLrT2/gQXhOz4E4xSphB8EXouild5qNOnZ6ZVXuTnf167z8xxSB10mxNey2gKDaIVig6I/tRFeYy6/N/QutbBlKI/+GNPjGCcVJI0hf7fTZGL4caTW8ggcXRz4LAsFp3JBf6Li0FVrGz5ojD0Etbl54BDn033q/tlVRhme5bXJ6s73yRg04kqdQsWVBRJwyzbUUmCQPrZd9i5Nh4QFVuhZljEyUWIStajE+c9v8OOiY1svv+XjKBjyWphP16HqgzvnEDf5+MQ5AUxE05IvJx43UY43CKTe3evzt4F/IqSdYwYGIQ55DaseRmf5zmHLU8MTTkksmOPQEzJL0nBzAmxyGV3PsMYPoIN+1/gJmxCO6ZaaCxYr9SFK/yoRW5e0PFX433xPhNsITBq7jUrVg6BQ/lr0ntRfvd7pRhFq8v02R3jWokL/99skxp1kjVF42bXEJXYPpHF3XAUhYscjOwmWj8dJgsIsSIKIjh7gRVYxQGrZQXOcJQjMytFgXy7fWHM= yuto@Yutos-MacBook-Pro.local" # Yuto's Sodium
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

