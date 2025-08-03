# Set direnv config
{ ... }:
{
  config = {
    programs.direnv = {
      enable = true;
      # Fish integration is automatically enabled
      nix-direnv = {
        enable = true;
      };
    };
  };
}
