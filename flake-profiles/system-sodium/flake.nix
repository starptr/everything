{
  description = "Yuto's system profiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs-firefox-darwin = {
      url = "github:bandithedoge/nixpkgs-firefox-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    herdr = {
      url = "github:ogulcancelik/herdr/v0.7.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    jellyfin-mpv-shim-darwin = {
      url = "path:./../../experimental/jellyfin-mpv-shim-darwin-compat";
      inputs.nixpkgs.follows = "nixpkgs"; # Follow modern nixpkgs (drops the stale apple_sdk_11_0 pin)
    };

    systems.url = "github:nix-systems/default"; # For soup
    soup = {
      url = "path:./../../soup";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixpkgs-devenv.follows = "nixpkgs"; # Does not need to be devenv's nixpkgs, since we don't use soup's devshell
        systems.follows = "systems";
        devenv.follows = "devenv";
      };
    };
    # TODO: remove these by removing them from soup
    # TODO: move soup into this monorepo
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
    extra-substituters = [
      "https://devenv.cachix.org"
      "https://nix-community.cachix.org"
    ];
  };

  outputs = inputs @ { self, nixpkgs, ... }: {
    darwinConfigurations."Yutos-Sodium" = inputs.nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        ./../../venus/modules/nixos-darwin/sodium.nix
        inputs.home-manager.darwinModules.home-manager
        {
          nixpkgs = {
            overlays = [
              (self: super: {
                jellyfin-mpv-shim = inputs.jellyfin-mpv-shim-darwin.packages."aarch64-darwin".default;
              })
              (final: super: {
                herdr = inputs.herdr.packages."aarch64-darwin".default;
              })
              #chaseln.overlays.chaseln
              inputs.soup.overlays.chaseln
              #inputs.soup.overlays.jujutsu
              (final: super: {
                jujutsu = inputs.soup.legacyPackages."aarch64-darwin".jujutsu-bin;
              })
              inputs.soup.overlays.claude-code-overlay
              (final: super: {
                check-gits = inputs.soup.legacyPackages."aarch64-darwin".check-gits;
              })
              (final: super: {
                lute3 = inputs.soup.legacyPackages."aarch64-darwin".lute3;
              })
              # HACK: skip broken tests until PR #502783 bumps resticprofile to 0.33.0
              (final: super: {
                resticprofile = super.resticprofile.overrideAttrs (o: { doCheck = false; });
              })
            ];
            config = import ./../../venus/app-configs/nixpkgs-config.nix; # Configures pkgs for evaluating this darwinConfiguration ("buildtime" config)
          };
        }
        {
          home-manager.useGlobalPkgs = true;
          #home-manager.useUserPackages = true; # This breaks fish??
          home-manager.users.yuto = {
            imports = [
              inputs.sops-nix.homeManagerModules.sops
              (import ./../../venus/modules/home-manager/sodium.nix)
            ];
          };
          home-manager.extraSpecialArgs = {
            inherit (inputs) nixpkgs;
          };
        }
      ];
    };
  };
}
