# Formerly `hm-base.nix`; do not use in new configurations!
{
  config,
  pkgs,
  lib,
  osConfig,
  ...
}:

# Base profile any time I use home-manager

let
  my-emacs = pkgs.emacs29-macport.override { };
  my-emacs-with-packages = (pkgs.emacsPackagesFor my-emacs).emacsWithPackages (epkgs: [
    epkgs.vterm
  ]);
in
{
  imports = [
    ./use-nixpkgs-config.nix
    ./use-alacritty.nix
  ];
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  #home.username = "yuto";
  #home.homeDirectory = "/Users/yuto";

  # useGlobalPkgs makes this ignored
  #nixpkgs = {
  #  config = import ./configs/nixpkgs-config.nix;
  #};

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = [
    # # Adds the 'hello' command to your environment. It prints a friendly
    # # "Hello, world!" when run.
    # pkgs.hello

    # This should not throw if unfree is allowed
    pkgs.hello-unfree

    pkgs.fd

    pkgs.ripgrep

    pkgs.emacs-all-the-icons-fonts

    #pkgs.mkvtoolnix
    #pkgs.handbrake # Broken
    #pkgs.ccextractor # Broken
    #pkgs.tsduck # Broken

    pkgs.age

    # Don't add project-local binaries to global userspace!!
    # pkgs.morph

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
  ];

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;

    # # You can also set the file content immediately.
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
  };

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. If you don't want to manage your shell through Home
  # Manager then you have to manually source 'hm-session-vars.sh' located at
  # either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/yuto/etc/profile.d/hm-session-vars.sh
  #
  home.sessionVariables = {
    # EDITOR = "emacs";
  };

  home.shellAliases = {
  };

  # Use homebrew; gh is very impure
  programs.gh = {
    enable = false;
  };

  programs.starship = {
    enable = true;
    settings = builtins.fromTOML (builtins.readFile ../../app-configs/starship.toml);
    enableFishIntegration = false;
  };

  # TODO: clean up firefox
  programs.firefox = {
    enable = false;

    package = pkgs.firefox-bin;
  };

  # TODO: clean up emacs
  programs.emacs = {
    enable = false;
    package = my-emacs-with-packages;
  };

  # FIXME: doesn't work on darwin
  #programs.vscode = {
  #  enable = true;
  #  package = pkgs.vscode.fhs;
  #  enableUpdateCheck = false;
  #};

  programs.git = {
    enable = true;
    #package = pkgs.git # Use the system git, as it contains Apple-specific patches (TODO: are they important?)
    delta = {
      enable = true;
    };
    includes = [
      {
        # Include the following in an emergency to use git with the old working configuration
        # TODO: Remove this after implementing the config directly in `programs.git.extraConfig`
        path = ../../legacy-yadm/git-config.txt;
      }
    ];
    userEmail = "yuto@berkeley.edu";
    userName = "Yuto Nishida";
  };

  programs.bat = {
    enable = true;
  };

  # Let Home Manager install and manage itself.
  # programs.home-manager.enable = true;

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "23.11"; # Please read the comment before changing.
}
