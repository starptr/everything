# NixOS module for publishing additional mDNS address aliases via avahi-publish
{ config, lib, pkgs, ... }:

let
  cfg = config.services.avahi-aliases;
in
{
  options.services.avahi-aliases = {
    enable = lib.mkEnableOption "Avahi address alias publishing for local machine";

    device = lib.mkOption {
      type = lib.types.str;
      example = "eth0";
      description = "Network device to get the LAN IP from";
    };

    aliases = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [ "myserver.local" "storage.local" ];
      description = ''
        List of domain aliases to publish via Avahi.
        All aliases must end with the configured Avahi domain (services.avahi.domainName).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = lib.all (alias: lib.hasSuffix ".${config.services.avahi.domainName}" alias) cfg.aliases;
      message = "All avahi-aliases must end with '.${config.services.avahi.domainName}'";
    }];

    # Create a systemd service for each alias using avahi-publish-address
    # avahi-publish-address runs as a daemon and publishes via D-Bus, avoiding collision issues
    systemd.services = lib.listToAttrs (map (alias:
      let
        # Convert alias to a safe service name (replace dots with dashes)
        serviceName = "avahi-alias-${builtins.replaceStrings ["."] ["-"] alias}";
      in
      lib.nameValuePair serviceName {
        description = "Publish mDNS alias ${alias}";
        after = [ "network-online.target" "avahi-daemon.service" ];
        wants = [ "network-online.target" ];
        requires = [ "avahi-daemon.service" ];
        wantedBy = [ "multi-user.target" ];

        # Restart if it fails (e.g., avahi-daemon restarts)
        serviceConfig = {
          Type = "simple";
          Restart = "on-failure";
          RestartSec = "5s";
        };

        script = ''
          set -euo pipefail

          # Get the IP address from the network device
          IP=$("${pkgs.iproute2}/bin/ip" -j -4 addr show dev "${cfg.device}" \
            | "${pkgs.jq}/bin/jq" -r '.[0].addr_info[] | select(.scope=="global") | .local')

          if [ -z "$IP" ]; then
            echo "Could not determine IP for device ${cfg.device}" >&2
            exit 1
          fi

          echo "Publishing ${alias} -> $IP"

          # avahi-publish-address runs in foreground and publishes the address record
          # Using --no-reverse to skip publishing reverse DNS (PTR) records
          exec "${pkgs.avahi}/bin/avahi-publish-address" --no-reverse "${alias}" "$IP"
        '';
      }
    ) cfg.aliases);

    # No cleanup script needed: avahi-publish-address is a long-running daemon that
    # automatically withdraws its mDNS records when the process exits. When NixOS
    # removes an alias or disables the module, the corresponding systemd service
    # stops and the record is withdrawn automatically.
  };
}
