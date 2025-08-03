{ config, pkgs, lib, ... }:
{
  imports = [
    ./venus-location.nix
    ./ooss-maker.nix
    #./use-fish.nix
    #./use-direnv.nix
    ./use-tealdeer.nix
    ./use-alacritty.nix
  ];
  config = {
    venus.ooss-maker-for-this-system = config.lib.file.mkOOSS-Magnesium-Hydroxide;
    #use-fish.enableHomebrewEscapeHatch = true;
    #use-fish.enableDarwinPathWorkaround = true;

    home.packages = [
      pkgs.iina
      #pkgs.ffmpeg-full
      pkgs.terminal-notifier
      pkgs.comma
      pkgs.lsd
      #pkgs.chaseln
      pkgs.neovim # Temporary until I figure out how to integrate ammonia into the sodium config
      #pkgs.check-gits
    ];

    home.sessionVariables = {
      MANPAGER = "${pkgs.neovim}/bin/nvim +Man!";
      #MANPAGER = "${pkgs.vim}/bin/vim +Man!"; # Doesn't work; you need to run `:runtime! ftplugin/main.vim<CR>:Man ` followed by the keyword
      #MANPAGER = "${pkgs.nvimpager}/bin/nvimpager";
      #MANPAGER = "${pkgs.bat-extras.batman}/bin/batman";
      EDITOR = "${pkgs.neovim}/bin/nvim";
    };

    home.shellAliases = {
      # This assumes this repo is in ~/src/venus
      drs = "darwin-rebuild switch --flake ${config.venus-location.magnesium-hydroxide}";
      #maybe-code = "/opt/homebrew/bin/code";

      "maybe-NH₂OH" = "nix run ${config.home.homeDirectory}/src/hydroxylamine";
      maybe-hydroxylamine = "maybe-NH₂OH";

      maybe-ammonia = "nix run ${config.home.homeDirectory}/src/ammonia";
      maybe-ammonia-cached = "${config.home.homeDirectory}/src/ammonia/result/bin/nvim";

      ban = ''BAT_THEME="Monokai Extended" ${pkgs.bat-extras.batman}/bin/batman''; # Select dark theme for dark alacritty
    };

    #home.file.".ssh/config".source = config.venus.ooss-maker-for-this-system "ssh-config.txt";

    # TODO: clean this up
    # This builds manual pages for the current intance of nixpkgs
    #home.file."nix-manuals/nixos-release".source = "${(import "${nixpkgs}/nixos/release.nix" { inherit nixpkgs; }).manualHTML.x86_64-linux}/share/doc/nixos";
    #home.file."nix-manuals/nixpkgs-manual".source = "${pkgs.nixpkgs-manual.override { inherit nixpkgs; }}/share/doc/nixpkgs";

    # TODO: clean this up
    xdg.configFile."ghostty/config".source = config.venus.ooss-maker-for-this-system "ghostty-config";
    
    # TODO: clean this up
    home.file.".emacs.d/init.el".source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/src/cyanide/result/init-file/init.el";

    # This value determines the Home Manager release that your configuration is
    # compatible with. This helps avoid breakage when a new Home Manager release
    # introduces backwards incompatible changes.
    #
    # You should not change this value, even if you update Home Manager. If you do
    # want to update the value, then make sure to first check the Home Manager
    # release notes.
    home.stateVersion = "23.11"; # Please read the comment before changing.
  };
}
