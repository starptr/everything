{ config, pkgs, ... }:

# This file is the equivalent of /etc/nixos/configuration.nix on darwin
let
  publicKeys = (import ../../../magic/common/constants.nix { lib = pkgs.lib; }).publicKeys;
in
{
  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = [
    pkgs.vim
    pkgs.nix-info
  ];

  # Use a custom configuration.nix location.
  # $ darwin-rebuild switch -I darwin-config=$HOME/.config/nixpkgs/darwin/configuration.nix
  # environment.darwinConfig = "$HOME/.config/nixpkgs/darwin/configuration.nix";

  fonts.packages = [
    pkgs.noto-fonts-cjk-sans
    pkgs.noto-fonts-cjk-serif
    pkgs.nerd-fonts.iosevka-term
    pkgs.nerd-fonts.inconsolata
    pkgs.inconsolata
  ];

  # Auto upgrade nix package and the daemon service.
  #services.nix-daemon.enable = true;

  services.yabai = {
    enable = false;
  };

  security.pam.services.sudo_local.touchIdAuth = true;

  system.defaults.CustomUserPreferences = {
    NSGlobalDomain.NSInitialToolTipDelay = 100;
    NSGlobalDomain.NSToolbarTitleViewRolloverDelay = 0;
    #NSGlobalDomain."com.apple.trackpad.scaling" = 5.134689; # Makes more sense to set in GUI # Values larger than 3 don't seem to make a difference
  };

  system.primaryUser = "yuto";
  system.defaults.".GlobalPreferences"."com.apple.mouse.scaling" = 2.0;
  system.defaults.LaunchServices.LSQuarantine = true;
  system.defaults.NSGlobalDomain.AppleInterfaceStyleSwitchesAutomatically = true;
  system.defaults.NSGlobalDomain.AppleShowAllExtensions = true;
  system.defaults.NSGlobalDomain.NSAutomaticCapitalizationEnabled = false;
  system.defaults.NSGlobalDomain.NSAutomaticDashSubstitutionEnabled = false;
  system.defaults.NSGlobalDomain.NSAutomaticPeriodSubstitutionEnabled = false;
  system.defaults.NSGlobalDomain.NSAutomaticSpellingCorrectionEnabled = false;
  system.defaults.NSGlobalDomain."com.apple.keyboard.fnState" = true;
  system.defaults.NSGlobalDomain._HIHideMenuBar = false;
  system.defaults.dock.autohide = true;
  system.defaults.dock.autohide-time-modifier = 0.2;
  system.defaults.finder = {
    AppleShowAllExtensions = true;
    FXDefaultSearchScope = "SCcf";
    FXPreferredViewStyle = "Nlsv";
    #ShowPathBar = true;
    _FXShowPosixPathInTitle = true;
  };

  # nix.package = pkgs.nix;
  nix = {
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
    settings.trusted-users = [
      "root"
      "@admin"
      "yuto"
    ];

    #distributedBuilds = true;
    #buildMachines = [
    #  {
    #    hostName = "x86_64.nix.yuto.sh";
    #    sshUser = "yuto";
    #    sshKey = "/Users/yuto/.ssh/id_rsa";
    #    system = "x86_64-linux";
    #    publicHostKey = "c3NoLXJzYSBBQUFBQjNOemFDMXljMkVBQUFBREFRQUJBQUFDQVFERThiZ1AyQithb1BUWU81V002aGh1WTNQT2M3VWZSSFdmd29pVDJXYzg1SnhNUVhRYkgxRjBPeTNZdHhPUFlMSFlrUkVuYTRJMkI4U1NWVTNFeFloTDNISWtaUXcvSloxdFdnMk9ZTTZ4WnUyMTdWL2pYWXo0TWxhMEFkNUhJb3cxMlo3MnZSTkhCQ3VUVE9NSGNOeTRCQk94TWE5TFhDRTNZb2o3TWJSZmRTNkFXejNLV1VYYzUvVmd1Q0JpLzBsVDFLQXRKN21PK0txQ1JNb1c5NU51L0N1c0hCT0h1dy9TdzhDY2FRd1g5WFZBOEs1N25Hcm9KbkJuTjBBalk3cHA3QXBCVjFBSzZkMk40UTBVY2lxSUdXOXM0NVM0cXk0Qk5kZW9UZXljUkZ6cDRmM3cwQXFQN0JHZzY4d0U1SDJZV29TQ2F5eDkwd2dBWW9oTnFrRGg2OUI0Z05aUmZUZ2JMUmZkNm1EZjQzYVNZWFo2bm0rY1dJVUg3Yk1iZElhYTA4NWFWNlc5TE9wcUMxU2RnVmt5MUJqVDRRbitMMzJQdlF4UEdtSU1UYVFZR2xqaW05WGJ1eG9WMjlRVEZweHNvZVBEV2lhT1ZUTVdMWWRYZTFEbkRhdUhPbnhLMERQMkRNY1pFUEZpQk1oWFVZSXZRbXFabUxGMWpHU3lLdGNTeGtkZnhtR1BwendXcUNBaElIamVhazk4U25WVXpNVlI4V05KQnRBNmhIUjBwWWxFdU93YkgrTTcyWnVsOWhnRWdUeGI1RVVmMHZxcVBnb0lPU2plSUZaQ2JZN0xJMEZmcFZGZkFSdUw5S0VDb0hzSTFCQW9CYXlJQ3ZEb2NURWtIVGt6SFU0QWFRN1NXQm5YN285b3AxZUdqS1ZaVlVlQmozYXVrMjhXUlE9PSByb290QG5peC1idWlsZGVyLXg4Ngo=";
    #    protocol = "ssh-ng";
    #  }
    #];
    # This automatically adds itself (aarch64-linux) to available buildMachines; no need for an entry above
    linux-builder = {
      enable = true;
      maxJobs = 4;
      # Advertise x86_64-linux in addition to the default aarch64-linux, and let the
      # aarch64 guest VM execute x86_64 build steps via QEMU binfmt. Container images
      # of prebuilt packages only emulate the tar/gzip assembly, so this stays cheap.
      # This is what lets whale's x86_64-linux images build on the M1 (see whale/readme.md).
      #
      # Note: after changing `config` here, `darwin-rebuild switch` only reloads the
      # service; the running VM keeps the old image until restarted. If x86_64 builds
      # fail with `path '…' is not valid` (guest store corruption), reset the builder:
      #   nix run ./flake-profiles/system-sodium#reset-linux-builder
      systems = [ "aarch64-linux" "x86_64-linux" ];
      config = {
        boot.binfmt.emulatedSystems = [ "x86_64-linux" ];
        # The VM defaults to 1 vCPU / 3 GB, so a single x86_64 cargo build (e.g. whale's
        # andref-ipfs-depot) grinds on one emulated core. Give it more so cargo parallelizes.
        # Sized to leave the M1 (8 cores / 16 GB) headroom for macOS: ~4 cores + 6 GB are used
        # ONLY while a build runs; the VM sits at ~0 when idle. Bump cautiously -- x86_64 steps run
        # under TCG (pure emulation), so each vCPU can peg a host core during a build.
        # mkForce: the nix-builder-vm profile already pins these (memorySize = 3072), so override.
        virtualisation.cores = pkgs.lib.mkForce 4;
        virtualisation.memorySize = pkgs.lib.mkForce (6 * 1024);  # MiB (was 3072)
      };
    };
  };

  # Create /etc/zshrc that loads the nix-darwin environment.
  programs.zsh.enable = true; # default shell on catalina
  programs.fish.enable = true;

  # For nix-darwin
  nixpkgs.hostPlatform = "aarch64-darwin";
  nixpkgs.config = import ../../app-configs/nixpkgs-config.nix;

  # User info
  users.users."yuto" = {
    name = "yuto";
    home = "/Users/yuto";
    shell = pkgs.fish;
    # Inbound SSH (the FINAL hop of a grand-central jump). A client jumps client -> grand-central
    # -> Sodium; grand-central only pipes raw TCP, so Sodium's own sshd authenticates the client
    # end-to-end and the client's key must live here. nix-darwin renders these to
    # /etc/ssh/nix_authorized_keys.d/yuto (see /etc/ssh/sshd_config.d/101-authorized-keys.conf).
    # Add the SAME dedicated public key you put in grand-central's clientKeys (main.jsonnet):
    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAA... grand-central <who>@<host>"   # generated per client; see plan
      publicKeys.ssh.magnesiumHydroxideForGrandCentral
    ];
  };

  # Enable macOS Remote Login (sshd) so the final hop above can land. nix-darwin's module does
  # the launchctl enable/bootstrap itself (it deliberately avoids `systemsetup -setremotelogin`,
  # which needs Full Disk Access) -- see modules/services/openssh.nix.
  services.openssh.enable = true;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;
}
