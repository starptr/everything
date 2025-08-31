{ config, pkgs, lib, ... }:

let
  # Assigned IP from the Tailscale dashboard
  # TODO: create a centralized `magic.nix` for magic values like this
  # We can set this statically, since
  # 1. the tailscale IP is stable
  # 2. it can be set in tailscale web dashboard to match this value
  tailscaleIp = "100.110.15.98"; 
  # List of ways to refer to this server in Tailscale from the Tailscale dashboard
  tlsSans = [
    # First name is advertised to agents
    "hydrogen-sulfide"
    "100.110.15.98"
    "hydrogen-sulfide.tail4c9a.ts.net"
    "fd7a:115c:a1e0::ca34:f62"
  ];
in let
  k3sExtraFlags = [
    "--node-ip=${tailscaleIp}"
    "--advertise-address=${tailscaleIp}"
  ] ++ (map (name: "--tls-san=${name}") tlsSans);
in
{
  system.stateVersion = "24.11";
  wsl.enable = true;
  wsl.defaultUser = "nixos"; # Do not change https://nix-community.github.io/NixOS-WSL/how-to/change-username.html

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
  systemd.services.tailscale-dns-redirect = {
    description = "Redirect DNS requests from Tailscale IP to CoreDNS in k3s";
    after = [ "network-online.target" "tailscaled.service" ];
    requires = [ "tailscaled.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = let
      serviceName = "tailscale-dns-redirect";
      systemdCat = "$SYSTEMD_CAT -t ${serviceName}";
      systemdCatErr = "$SYSTEMD_CAT -t ${serviceName} --priority err";
      iptableRuleMacro = ''PREROUTING --protocol "$1" --destination $TAILSCALE_IP --dport 53 --jump REDIRECT --to-port 1053'';
    in {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 10; # Wait 10 seconds before a restart
      StartLimitIntervalSec = 60 * 3; # Within this many seconds, only allow StartLimitBurst number of restarts
      StartLimitBurst = 10;
      ExecStart = pkgs.writeShellScript "${serviceName}-start" ''
        set -eux

        IP_CMD=${pkgs.iproute2}/bin/ip
        IPTABLES=${pkgs.iptables}/bin/iptables
        SYSTEMD_CAT=${pkgs.systemd}/bin/systemd-cat

        # $IP_CMD exits with an error if a match isn't found; ignore such errors.
        # grep also exits with an error if a match isn't found; ignore such errors.
        TAILSCALE_IP=$($IP_CMD -4 addr show dev tailscale0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
        if [ -z "$TAILSCALE_IP" ]; then
          echo "TAILSCALE_IP is empty or tailscale0 interface is down" | ${systemdCatErr}
          exit 1
        fi
        echo $TAILSCALE_IP > /run/tailscale-ip

        add_rule() {
          if ! $IPTABLES -t nat --check ${iptableRuleMacro} 2>/dev/null; then
            $IPTABLES -t nat --append ${iptableRuleMacro}
            echo "Added $1 rule for Tailscale IP $TAILSCALE_IP" | ${systemdCat}
          else
            echo "$1 rule for Tailscale IP $TAILSCALE_IP already exists" | ${systemdCat}
          fi
        }

        add_rule udp
        add_rule tcp
      '';
      ExecStop = pkgs.writeShellScript "${serviceName}-stop" ''
        set -eux

        IPTABLES=${pkgs.iptables}/bin/iptables
        SYSTEMD_CAT=${pkgs.systemd}/bin/systemd-cat
        TAILSCALE_IP=$(cat /run/tailscale-ip)

        del_rule() {
          if $IPTABLES -t nat --check ${iptableRuleMacro} 2>/dev/null; then
            $IPTABLES -t nat --delete ${iptableRuleMacro}
            echo "Removed $1 rule for Tailscale IP $TAILSCALE_IP" | ${systemdCat}
          else
            echo "No $1 rule to remove for Tailscale IP $TAILSCALE_IP" | ${systemdCat}
          fi
        }

        del_rule udp
        del_rule tcp
      '';
    };
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
  };

  services.k3s = {
    enable = true;
    role = "server";
    clusterInit = false;
    extraFlags = k3sExtraFlags;
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
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDLrT2/gQXhOz4E4xSphB8EXouild5qNOnZ6ZVXuTnf167z8xxSB10mxNey2gKDaIVig6I/tRFeYy6/N/QutbBlKI/+GNPjGCcVJI0hf7fTZGL4caTW8ggcXRz4LAsFp3JBf6Li0FVrGz5ojD0Etbl54BDn033q/tlVRhme5bXJ6s73yRg04kqdQsWVBRJwyzbUUmCQPrZd9i5Nh4QFVuhZljEyUWIStajE+c9v8OOiY1svv+XjKBjyWphP16HqgzvnEDf5+MQ5AUxE05IvJx43UY43CKTe3evzt4F/IqSdYwYGIQ55DaseRmf5zmHLU8MTTkksmOPQEzJL0nBzAmxyGV3PsMYPoIN+1/gJmxCO6ZaaCxYr9SFK/yoRW5e0PFX433xPhNsITBq7jUrVg6BQ/lr0ntRfvd7pRhFq8v02R3jWokL/99skxp1kjVF42bXEJXYPpHF3XAUhYscjOwmWj8dJgsIsSIKIjh7gRVYxQGrZQXOcJQjMytFgXy7fWHM= yuto@Yutos-MacBook-Pro.local"
      ];
    };
    "root" = {
      openssh.authorizedKeys.keys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDLrT2/gQXhOz4E4xSphB8EXouild5qNOnZ6ZVXuTnf167z8xxSB10mxNey2gKDaIVig6I/tRFeYy6/N/QutbBlKI/+GNPjGCcVJI0hf7fTZGL4caTW8ggcXRz4LAsFp3JBf6Li0FVrGz5ojD0Etbl54BDn033q/tlVRhme5bXJ6s73yRg04kqdQsWVBRJwyzbUUmCQPrZd9i5Nh4QFVuhZljEyUWIStajE+c9v8OOiY1svv+XjKBjyWphP16HqgzvnEDf5+MQ5AUxE05IvJx43UY43CKTe3evzt4F/IqSdYwYGIQ55DaseRmf5zmHLU8MTTkksmOPQEzJL0nBzAmxyGV3PsMYPoIN+1/gJmxCO6ZaaCxYr9SFK/yoRW5e0PFX433xPhNsITBq7jUrVg6BQ/lr0ntRfvd7pRhFq8v02R3jWokL/99skxp1kjVF42bXEJXYPpHF3XAUhYscjOwmWj8dJgsIsSIKIjh7gRVYxQGrZQXOcJQjMytFgXy7fWHM= yuto@Yutos-MacBook-Pro.local"
      ];
    };
  };

  sops = {
    secrets."milky-way-token.txt" = {
      format = "binary";
      mode = "0400";
      sopsFile = ./../../../secrets/milky-way-token.txt;
    };
  };
}