# Set alacritty config
{ config, pkgs, ... }:
{
  imports = [ ./ooss-maker.nix ];
  config = {
    home.packages = [ pkgs.alacritty ];
    xdg.configFile = {
      #"alacritty/alacritty.toml".source = config.lib.file.mkOutOfStoreSymlink "/Users/yuto/.nixpkgs/hot-files/alacritty.toml";
      "alacritty/alacritty.toml".source = config.venus.ooss-maker-for-this-system "alacritty.toml";
    };
    programs.alacritty = {
      enable = false; # Use xdg.configFile and mkOutOfStoreSymlink instead
      # TODO: clean up toml config
      # The text is 2 sizes too big
      # Keybinds are suspicious
      # TODO: override src to control the pinned version (0.12.0) (5a72819)
      # Ideally, pin the package since alacritty is unstable
      # Then, use xdg to symlink to the yaml. Probably best to create a new homeManagerPartial for this.
      settings = builtins.fromTOML (builtins.readFile ../legacy-yadm/alacritty/alacritty.toml);
    };
  };
}
