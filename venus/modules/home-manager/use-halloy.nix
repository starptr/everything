# Set halloy config
{ pkgs, ... }:
{
  config = {
    xdg = {
      configFile."halloy/config.toml".source = ./../configs/halloy-config.toml;
    };

    home.packages = [ pkgs.halloy ];
  };
}
