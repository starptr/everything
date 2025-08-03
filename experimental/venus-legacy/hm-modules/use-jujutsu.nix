# Set personal jujutsu configuration
{
  config,
  pkgs,
  lib,
  osConfig,
  ...
}:
{
  config = {
    programs.jujutsu = {
      enable = true;
      settings = {
        user = {
          name = "Yuto Nishida"; # TODO: consolidate magic values
          email = "yuto@berkeley.edu"; # TODO: consolidate magic values
        };
      };
    };
  };
}
