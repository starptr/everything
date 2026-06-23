{ config, pkgs, lib, ... }:

let
  publicKeys = (import ../../../magic/common/constants.nix { inherit lib; }).publicKeys;
  # Assigned IP from the Tailscale dashboard
  # TODO: create a centralized `magic.nix` for magic values like this
  # We can set this statically, since
  # 1. the tailscale IP is stable
  # 2. it can be set in tailscale web dashboard to match this value
  tailscaleIp = "100.110.15.98"; 
  controlPlaneNodeIp = "100.112.134.68";
  controlPlaneNodePort = "6443";
  # List of ways to refer to this server in Tailscale from the Tailscale dashboard
in
{
  imports = [
    ./use-tailscale-dns-redirect.nix
    ./use-passwordless-shutdown.nix
  ];
  config = {
    system.stateVersion = "24.11";
    wsl.enable = true;
    wsl.defaultUser = "nixos"; # Do not change https://nix-community.github.io/NixOS-WSL/how-to/change-username.html
    wsl.docker.enable = true; # Requires Docker Desktop installed on Windows host

    networking.hostName = "Hydrogen-Sulfide";

    # The firewall service is disabled in WSL NixOS.
    #systemd.services.firewall.enable = lib.mkForce true;
    #networking.firewall = {
    #  enable = true;
    #  extraCommands = ''
    #    iptables --table nat --append PREROUTING --protocol udp --destination ${tailscaleIp} --dport 53 --jump REDIRECT --to-port 1053
    #    iptables --table nat --append PREROUTING --protocol tcp --destination ${tailscaleIp} --dport 53 --jump REDIRECT --to-port 1053
    #  '';
    #  extraStopCommands = ''
    #    iptables --table nat --delete PREROUTING --protocol udp --destination ${tailscaleIp} --dport 53 --jump REDIRECT --to-port 1053 || true
    #    iptables --table nat --delete PREROUTING --protocol tcp --destination ${tailscaleIp} --dport 53 --jump REDIRECT --to-port 1053 || true
    #  '';
    #};

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # Allow unfree packages
    nixpkgs.config.allowUnfree = true;

    services.tailscale = {
      enable = true;
      useRoutingFeatures = "both";
    };

    systemd.services.k3s = {
      after = [ "tailscaled.service" ];
      requires = [ "tailscaled.service" ];
      path = [
        pkgs.tailscale # Required by the vpn-auth-file tailscale integration
      ];
    };
    services.k3s = {
      enable = true;
      role = "agent";
      # Must be tailscale IP
      serverAddr = "https://${controlPlaneNodeIp}:${controlPlaneNodePort}";
      tokenFile = "/run/secrets/cluster_token";
      extraFlags = [
        "--vpn-auth-file=/run/secrets/k3s_vpn_auth"
        "--node-external-ip=${tailscaleIp}"
      ];
      gracefulNodeShutdown = {
        enable = true;
      };
    };

    services.pipewire = {
      enable = true;
      #socketActivation = false;
      systemWide = true;
      pulse.enable = true;
    };
    users.users.mopidy.extraGroups = [ "pipewire" ];
    systemd.services.mopidy.serviceConfig.SupplementaryGroups = [ "pipewire" ];
    services.mopidy = {
      enable = true;
      extensionPackages = let
        mopidy-overriden-pkgs = pkgs.mopidyPackages.overrideScope (prev: final: {
          extraPkgs = pkgs: [
            pkgs.yt-dlp
          ];
        });
      in [
        pkgs.mopidy-local
        pkgs.mopidy-mpd
        pkgs.mopidy-spotify
        pkgs.mopidy-iris
        mopidy-overriden-pkgs.mopidy-youtube
      ];
      configuration = ''
        [youtube]
        youtube_dl_package = yt_dlp
      '';
      # Must be a secret, since it contains credentials
      extraConfigFiles = [ "/run/secrets/mopidy-config" ];
    };

    services.openssh = {
      enable = true;
    };

    programs.fish = {
      enable = true;
    };

    users.users = {
      "nixos" = {
        shell = pkgs.fish;
        openssh.authorizedKeys.keys = [
          publicKeys.ssh.yutoSodium
        ];
      };
      "root" = {
        openssh.authorizedKeys.keys = [
          publicKeys.ssh.yutoSodium
        ];
      };
    };

    sops = {
      secrets."cluster_token" = {
        mode = "0400";
        sopsFile = ./../../../secrets/milky-way.json;
      };
      secrets."k3s_vpn_auth" = {
        mode = "0400";
        sopsFile = ./../../../secrets/milky-way.json;
      };
      secrets."mopidy-config" = {
        format = "binary";
        mode = "0444";
        sopsFile = ./../../../secrets/mopidy-config.toml.txt;
      };
    };
  };
}