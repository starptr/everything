{ modulesPath, lib, pkgs, config, ... }: let
  # Assigned IP from the Tailscale dashboard
  # TODO: create a centralized `magic.nix` for magic values like this
  # We can set this statically, since
  # 1. the tailscale IP is stable
  # 2. it can be set in tailscale web dashboard to match this value
  tailscaleIp = "100.127.189.16"; 
  controlPlaneNodeIp = "100.112.134.68";
  controlPlaneNodePort = "6443";
in {
  imports = lib.optional (builtins.pathExists ./do-userdata.nix) ./do-userdata.nix ++ [
    (modulesPath + "/virtualisation/digital-ocean-config.nix")
    #./use-tailscale-dns-redirect.nix
  ];

  environment.systemPackages = [
    pkgs.rclone
    pkgs.vim
    pkgs.chaseln
    pkgs.htop
    pkgs.dig
    pkgs.ghostty.terminfo
    pkgs.etcd
    pkgs.lsof
  ];

  nix = {
    settings.experimental-features = [ "nix-command" "flakes" ];
  };

  system.stateVersion = "23.11"; # Do not change lightly!

  # Config from the base image
  swapDevices = [
    {
      device = "/swapfile";
      size = 3072;
    }
  ];
  users.mutableUsers = false;
  users.users.yuto = {
    isNormalUser = true;
    shell = pkgs.bash;
    description = "Yuto";
    password = "";
    createHome = true;
    homeMode = "755"; # Let other users read/search (eg. Komga) (The x bit for directories is actually for searching)
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDLrT2/gQXhOz4E4xSphB8EXouild5qNOnZ6ZVXuTnf167z8xxSB10mxNey2gKDaIVig6I/tRFeYy6/N/QutbBlKI/+GNPjGCcVJI0hf7fTZGL4caTW8ggcXRz4LAsFp3JBf6Li0FVrGz5ojD0Etbl54BDn033q/tlVRhme5bXJ6s73yRg04kqdQsWVBRJwyzbUUmCQPrZd9i5Nh4QFVuhZljEyUWIStajE+c9v8OOiY1svv+XjKBjyWphP16HqgzvnEDf5+MQ5AUxE05IvJx43UY43CKTe3evzt4F/IqSdYwYGIQ55DaseRmf5zmHLU8MTTkksmOPQEzJL0nBzAmxyGV3PsMYPoIN+1/gJmxCO6ZaaCxYr9SFK/yoRW5e0PFX433xPhNsITBq7jUrVg6BQ/lr0ntRfvd7pRhFq8v02R3jWokL/99skxp1kjVF42bXEJXYPpHF3XAUhYscjOwmWj8dJgsIsSIKIjh7gRVYxQGrZQXOcJQjMytFgXy7fWHM= yuto@Yutos-MacBook-Pro.local" # Yuto's Sodium
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPtVvX9uhSWD1DPBIRqgkNzFXqjdqvWB/WtDy4seaiJl" # 1Password "ssh key - main"
    ];
  };

  # /var/lib/acme/.challenges must be writable by the ACME user
  # and readable by the Nginx user. The easiest way to achieve
  # this is to add the Nginx user to the ACME group.
  #users.users.nginx.extraGroups = [ "acme" ];

  # Let's Encrypt
  # see https://discourse.nixos.org/t/nixos-nginx-acme-ssl-certificates-for-multiple-domains/19608/3 for an example
  #security.acme = {
  #  acceptTerms = true;
  #  defaults = {
  #    email = "acme.management@yart.me";
  #    dnsProvider = "cloudflare";
  #  };
  #  #certs."sp.nixie.yuto.sh" = {
  #  #  dnsProvider = null;
  #  #  webroot = config.services.nginx.virtualHosts."acmechallenge.yuto.sh".locations."/.well-known/acme-challenge".root;
  #  #  # Ensure that the web server you use can read the generated certs
  #  #  # Take a look at the group option for the web server you choose.
  #  #  group = "nginx";
  #  #  # Since we have a wildcard vhost to handle port 80,
  #  #  # we can generate certs for anything!
  #  #  # Just make sure your DNS resolves them.
  #  #  #extraDomainNames = [ "mail.example.com" ];
  #  #};
  #};
  security.sudo.wheelNeedsPassword = false;

  # Nixie-specific config
  #networking.firewall = {
  #  enable = true;
  #  allowedTCPPorts = [ 22 80 443 ];
  #  allowedUDPPorts = [ 443 ];
  #};
  networking.hostName = "ethane";

  #services.nginx = {
  #  enable = true;
  #  recommendedGzipSettings = true;
  #  recommendedOptimisation = true;
  #  recommendedProxySettings = true;
  #  recommendedTlsSettings = true;
  #  virtualHosts."hello-nginx.nixie.yuto.sh" = {
  #    enableACME = true;
  #    addSSL = true;
  #    #locations."/".proxyPass = "http://127.0.0.1:9955/";
  #    locations."/".extraConfig = ''
  #      default_type text/html;
  #      return 200 "<!DOCTYPE html><h1>Hello from hello-nginx!</h1>\n";
  #    '';
  #  };
  #  #virtualHosts."komga.nixie.yuto.sh" = {
  #  #  enableACME = true;
  #  #  addSSL = true;
  #  #  locations."/".extraConfig = ''
  #  #    proxy_pass http://127.0.0.1:${builtins.toString config.services.komga.port};
  #  #  '';
  #  #};
  #  virtualHosts."acmechallenge.yuto.sh" = {
  #    # For acme HTTP challenge
  #    locations."/.well-known/acme-challenge" = {
  #      root = "/var/lib/acme/.challenges";
  #    };
  #  };
  #};

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

  sops = {
    secrets."cluster_token" = {
      mode = "0400";
      sopsFile = ./../../../secrets/milky-way.json;
    };
    secrets."k3s_vpn_auth" = {
      mode = "0400";
      sopsFile = ./../../../secrets/milky-way.json;
    };
  };
}