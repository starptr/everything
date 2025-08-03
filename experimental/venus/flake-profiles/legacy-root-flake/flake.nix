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
    flake-utils.url = "github:numtide/flake-utils";
    jellyfin-mpv-shim-darwin = {
      url = "github:starptr/jellyfin-mpv-shim.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixpkgs-devenv.url = "github:cachix/devenv-nixpkgs/rolling";
    systems.url = "github:nix-systems/default";
    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs-devenv";
    };

    soup = {
      url = "github:starptr/soup";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixpkgs-devenv.follows = "nixpkgs-devenv";
        systems.follows = "systems";
        devenv.follows = "devenv";
      };
    };
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

  outputs =
    inputs@{
      self,
      home-manager,
      nix-darwin,
      nixpkgs,
      nixpkgs-devenv,
      sops-nix,
      devenv,
      flake-utils,
      jellyfin-mpv-shim-darwin,
      soup,
      ...
    }:
    (flake-utils.lib.eachDefaultSystem (
      system:
      let
        # TODO: remove `import` and use `pkgs = nixpkgs.legacyPackages.${system};`
        pkgs = import nixpkgs {
          inherit system;
          config = import ../../configs/nixpkgs-config.nix; # Configures pkgs just for the following attributes, i.e. devShells and formatter
        };
        devpkgs = nixpkgs-devenv.legacyPackages.${system};
      in
      {
        devShells.using-devenv = devenv.lib.mkShell {
          inherit inputs;
          pkgs = devpkgs;
          modules = [ (import ../../devenv.nix) ];
        };
        devShells.using-sops = pkgs.mkShell {
          buildInputs = [
            pkgs.sops
            pkgs.ssh-to-age
          ];
          shellHook = ''
            echo "Replacing the spawned shell with fish…"
            exec ${pkgs.fish}/bin/fish # --init-command "source .venv/bin/activate.fish"
          '';
        };
        devShells.default = self.devShells.${system}.using-devenv;
        formatter = pkgs.nixfmt-rfc-style;
      }
    ))
    // (
      let
        overlay-jellyfin-mpv-shim-for-aarch64-darwin = self: super: {
          jellyfin-mpv-shim = jellyfin-mpv-shim-darwin.packages."aarch64-darwin".default;
        };
      in
      {
        #homeConfigurations."main" = home-manager.lib.homeManagerConfiguration {
        #  pkgs = nixpkgs;
        #  modules = [
        #    ../../home-yuto.nix
        #  ];
        #};
        homeConfigurations."starptr-tilderef2" = home-manager.lib.homeManagerConfiguration {
          pkgs = nixpkgs.legacyPackages."x86_64-linux";
          modules = [
            ../../hm-modules/tilderef2-starptr.nix
          ];
        };

        # Magnesium Hydroxide (managed system doesn't allow changing the system name)
        darwinConfigurations."KF4459NYXQ" = nix-darwin.lib.darwinSystem {
          system = "aarch64-darwin";
          modules = [
            ../../magnesium-hydroxide/darwin-configuration.nix
            home-manager.darwinModules.home-manager
            {
              nixpkgs = {
                config = import ../../configs/nixpkgs-config.nix;
              };
            }
            {
              home-manager.useGlobalPkgs = true;
              home-manager.users."yuto.nishida" = {
                imports = [
                  (import ../../hm-modules/magnesium-hydroxide.nix)
                ];
              };
            }
          ];
        };
        darwinConfigurations."Yutos-Magnesium-Chloride" = nix-darwin.lib.darwinSystem {
          system = "aarch64-darwin";
          modules = [
            ../../darwin-configuration.nix
            home-manager.darwinModules.home-manager
            {
              #nixpkgs.overlays = [ inputs.nixpkgs-firefox-darwin.overlay ];
              home-manager.useGlobalPkgs = true;
              #home-manager.useUserPackages = true; # This breaks fish??
              home-manager.users.yuto = {
                imports = [
                  #self.homeManagerPartial."base"
                  #self.homeManagerPartial."macos"
                ];
              };
            }
          ];
        };
        darwinConfigurations."Yutos-Sodium" = nix-darwin.lib.darwinSystem {
          system = "aarch64-darwin";
          modules = [
            ../../darwin-configuration.nix
            home-manager.darwinModules.home-manager
            {
              nixpkgs = {
                overlays = [
                  overlay-jellyfin-mpv-shim-for-aarch64-darwin
                  #chaseln.overlays.chaseln
                  soup.overlays.chaseln
                  (final: super: {
                    check-gits = soup.legacyPackages."aarch64-darwin".check-gits;
                  })
                ];
                config = import ../../configs/nixpkgs-config.nix; # Configures pkgs for evaluating this darwinConfiguration ("buildtime" config)
              };
            }
            {
              #nixpkgs.overlays = [ inputs.nixpkgs-firefox-darwin.overlay ];
              home-manager.useGlobalPkgs = true;
              #home-manager.useUserPackages = true; # This breaks fish??
              home-manager.users.yuto = {
                imports = [
                  sops-nix.homeManagerModules.sops
                  (import ../../hm-modules/sodium.nix)
                ];
              };
              home-manager.extraSpecialArgs = {
                inherit nixpkgs;
              };

              #{
              #  # home.nix
              #  programs.firefox = {
              #    enable = true;

              #    # IMPORTANT: use a package provided by the overlay (ends with `-bin`)
              #    # see overlay.nix for all possible packages
              #    package = nixpkgs.firefox-bin; # Or pkgs.librewolf if you're using librewolf
              #  };
              #  home.stateVersion = "23.11";
              #};
            }
          ];
        };
        nixosConfigurations."Yutos-Aluminum-Nitride" = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ../../aluminum-nitride/configuration.nix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.yuto = import ../../aluminum-nitride/hm.nix;
              home-manager.backupFileExtension = "hm-backup";
            }
          ];
        };
      }
    );
}
