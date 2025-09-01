{
  description = "Yuto's system profiles";

  inputs = {
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
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

    soup = {
      url = "github:starptr/soup";
      inputs = {
        nixpkgs.follows = "nixpkgs";
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
      nixpkgs,
      sops-nix,
      jellyfin-mpv-shim-darwin,
      soup,
      ...
    }: let
      overlay-jellyfin-mpv-shim-for-aarch64-darwin = self: super: {
        jellyfin-mpv-shim = jellyfin-mpv-shim-darwin.packages."aarch64-darwin".default;
      };
    in
    {
      nixosConfigurations."Yutos-Aluminum-Nitride" = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./../../venus/modules/nixos-darwin/aluminum-nitride.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.yuto = import ./../../venus/modules/home-manager/aluminum-nitride.nix;
            home-manager.backupFileExtension = "hm-backup";
          }
        ];
      };

      deploy.nodes.aluminum-nitride = {
        hostname = "aluminum-nitride";
        profilesOrder = [ "system" ];
        profiles.system = {
          user = "root";
          sshUser = "root";
          path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations."Yutos-Aluminum-Nitride";
          remoteBuild = true;
        };
      };
    };
}
