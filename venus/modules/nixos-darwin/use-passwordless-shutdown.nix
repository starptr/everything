{ config, pkgs, ... }:
{
  # Configure sudo
  security.sudo = {
    extraRules = [
      {
        groups = [ "wheel" ];
        commands = [
          { command = "/run/current-system/sw/bin/systemctl poweroff"; options = [ "NOPASSWD" ]; }
        ];
      }
    ];
  };
}
