{ pkgs, ... } : {
  config = {
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
  };
}