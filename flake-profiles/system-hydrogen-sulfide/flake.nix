{
  description = "Yuto's system profiles";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
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

  outputs = inputs @ { self, nixpkgs, nixos-wsl, home-manager, ... }: {
    nixosConfigurations."Hydrogen-Sulfide" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        inputs.sops-nix.nixosModules.sops
        nixos-wsl.nixosModules.default
        ./../../venus/modules/nixos-darwin/hydrogen-sulfide.nix
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.nixos = import ./../../venus/modules/home-manager/hydrogen-sulfide.nix;
          home-manager.backupFileExtension = "hm-backup";
        }
      ];
    };

    deploy.nodes."Hydrogen-Sulfide" = {
      hostname = "hydrogen-sulfide.tail4c9a.ts.net";
      profilesOrder = [ "system" ];
      profiles.system = {
        user = "root";
        sshUser = "root";
        path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations."Hydrogen-Sulfide";
        remoteBuild = true;
      };
    };
    
    # This is highly advised, and will prevent many possible mistakes
    # Disabled to avoid remote builder
    #checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) inputs.deploy-rs.lib;
  };
}
