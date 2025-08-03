# Set personal fish shell configuration
{
  config,
  pkgs,
  lib,
  osConfig,
  ...
}:
{
  options = {
    use-fish.enableHomebrewEscapeHatch = lib.mkOption {
      default = false;
      type = lib.types.bool;
      description = ''
        Enable a command for homebrew initialization in fish shell.
      '';
    };
    use-fish.enableDarwinPathWorkaround = lib.mkOption {
      default = false;
      type = lib.types.bool;
      description = ''
        Enable a hacky workaround for the bugged fish shell path on Darwin.
        HACK: See https://github.com/LnL7/nix-darwin/issues/122#issuecomment-1659465635 and https://github.com/LnL7/nix-darwin/issues/122#issuecomment-1666623924
      '';
    };
  };
  config = lib.mkMerge [
    {
      programs.fish = {
        enable = true;
        functions = {
          d = ''
            # This function is defined in home-yuto.nix
            if [ "$PWD" = "$HOME/Downloads" ]
              ${pkgs.lsd}/bin/lsd -A --sort time $argv
            else
              ${pkgs.lsd}/bin/lsd -A $argv
            end
          '';
          da = ''
            # This function is defined in home-yuto.nix
            if [ "$PWD" = "$HOME/Downloads" ]
              ${pkgs.lsd}/bin/lsd -Alr --sort time $argv
            else
              ${pkgs.lsd}/bin/lsd -Al $argv
            end
          '';
        };

        plugins = [
          {
            name = "tide";
            src = pkgs.fishPlugins.tide.src;
          }
          {
            name = "done";
            src = pkgs.fishPlugins.done.src;
          }
        ];
      };
    }
    (lib.mkIf config.use-fish.enableHomebrewEscapeHatch {
      programs.fish.functions.legacy-brew-init = ''
        # Initializes brew in fish, as was done in ~/.zprofile
        # This function is defined in home-yuto.nix
        /opt/homebrew/bin/brew shellenv | source
      '';
    })
    (lib.mkIf config.use-fish.enableDarwinPathWorkaround {
      programs.fish.loginShellInit =
        let
          # This naive quoting is good enough in this case. There shouldn't be any
          # double quotes in the input string, and it needs to be double quoted in case
          # it contains a space (which is unlikely!)
          dquote = str: "\"" + str + "\"";

          makeBinPathList = map (path: path + "/bin");
        in
        ''
          fish_add_path --move --prepend --path ${
            lib.concatMapStringsSep " " dquote (makeBinPathList osConfig.environment.profiles)
          }
          set fish_user_paths $fish_user_paths
        '';
    })
  ];
}
