# Main hm module for the starptr profile on tilderef2
{ config, pkgs, lib, ... }:
{
  imports = [
    ./venus-location.nix
    ./use-fish.nix
    ./use-tealdeer.nix
    ./use-direnv.nix
  ];
  home.stateVersion = "24.05";
  home.username = "starptr";
  home.homeDirectory = "/home/starptr";

  home.packages = [
    pkgs.radicle-node
  ];

  programs.home-manager.enable = true;

  programs.ripgrep.enable = true;

  systemd.user.startServices = true;
  systemd.user.services = {
    set-bot = {
      Unit = {
        Description = "set-bot service";
        After = [ "network.target" ];
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
      Service = {
        Type = "exec";
        #User = "starptr"; # This breaks user services, since setting the user requires elevated perms
        Restart = "on-failure";
        WorkingDirectory = ''/home/starptr/src/set/app'';
        ExecStart = ''/home/starptr/src/set/app/target/debug/set-bot'';
      };
    };
    radish = {
      Unit = {
        Description = "radicle on login";
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
      Service = {
        Type = "exec";
        Environment = ''"PATH=${lib.makeBinPath [ pkgs.radicle-node ]}:$PATH"'';
        ExecStart = ''${pkgs.radicle-node}/bin/rad node start --foreground --verbose'';
        PAMName = "login";
      };
    };
  };
}
