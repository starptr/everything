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
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  #home.username = "yuto";
  #home.homeDirectory = "/Users/yuto";

  # useGlobalPkgs makes this ignored
  #nixpkgs = {
  #  config = import ./configs/nixpkgs-config.nix;
  #};

  xdg = {
    enable = true;
    # Configure commands like `nix-shell` (eg. `allowUnfree`)
    configFile."nixpkgs/config.nix".source = ./../../../venus/app-configs/nixpkgs-config.nix;
  };

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = [
    # # Adds the 'hello' command to your environment. It prints a friendly
    # # "Hello, world!" when run.
    # pkgs.hello

    # This should not throw if unfree is allowed
    pkgs.hello-unfree

    pkgs.moreutils

    pkgs.fd

    pkgs.ripgrep

    pkgs.emacs-all-the-icons-fonts

    #pkgs.mkvtoolnix
    #pkgs.handbrake # Broken
    #pkgs.ccextractor # Broken
    #pkgs.tsduck # Broken

    #pkgs.terminal-notifier

    pkgs.age

    pkgs.comma

    pkgs.gparted

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
    nrs = "sudo nixos-rebuild switch --flake ~/src/venus";
  };

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

  programs.direnv = {
    enable = true;
    # Fish integration is automatically enabled
    nix-direnv = {
      enable = true;
    };
  };

  # Use homebrew; gh is very impure
  programs.gh = {
    enable = true;
  };

  programs.starship = {
    enable = true;
    settings = builtins.fromTOML (builtins.readFile ./../../../venus/app-configs/starship.toml);
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

  programs.alacritty = {
    enable = true;
    # TODO: clean up toml config
    # The text is 2 sizes too big
    # Keybinds are suspicious
    # TODO: override src to control the pinned version (0.12.0) (5a72819)
    # Ideally, pin the package since alacritty is unstable
    # Then, use xdg to symlink to the yaml. Probably best to create a new homeManagerPartial for this.
    settings = builtins.fromTOML (builtins.readFile ./../../../venus/legacy-yadm/alacritty/alacritty.toml);
  };

  # FIXME: doesn't work on darwin
  #programs.vscode = {
  #  enable = true;
  #  package = pkgs.vscode.fhs;
  #  enableUpdateCheck = false;
  #};

  programs.yt-dlp = {
    enable = false;
  };

  programs.git = {
    enable = true;
    #package = pkgs.git # Use the system git, as it contains Apple-specific patches (TODO: are they important?)
    delta = {
      enable = true;
    };
    userEmail = "yuto@berkeley.edu";
    userName = "Yuto Nishida";
    extraConfig = {
      credential.helper = "oauth";
    };
  };

  programs.ssh = {
    enable = true;
  };

  programs.bat = {
    enable = true;
  };

  programs.tealdeer = {
    enable = true;
    settings = {
      display = {
        compact = true;
      };
    };
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
  home.stateVersion = "24.05"; # Please read the comment before changing.
}
