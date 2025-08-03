# Use a sane nixpkgs/config.nix file (eg. allowUnfree)
{ ... }:
{
  config = {
    xdg = {
      enable = true;
      # Configure commands like `nix-shell` (eg. `allowUnfree`) (i.e. "runtime" configuration)
      configFile."nixpkgs/config.nix".source = ./../configs/nixpkgs-config.nix;
    };
  };
}
