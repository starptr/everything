{
  inputs = {
    nixpkgs-tilderef.url = "github:NixOS/nixpkgs/nixos-unstable";
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs-tilderef";
    };

    systems.url = "github:nix-systems/default";

    cursor-server = {
      url = "github:strickczq/nixos-cursor-server";
      inputs.nixpkgs.follows = "nixpkgs-tilderef";
    };
  };
  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };
  outputs =
    {
      self,
      nixpkgs-tilderef,
      deploy-rs,
      systems,
      cursor-server,
    }@inputs:
    let
      generated = builtins.fromJSON (builtins.readFile ./../../exports/jupiter/generated.json);
      generated-serverref-data-from-pulumi = generated.serverref;
      forEachSystem = nixpkgs-tilderef.lib.genAttrs (import systems);
    in
    {
      nixosConfigurations.serverref = nixpkgs-tilderef.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ 
          cursor-server.nixosModules.default
          ./../../venus/modules/nixos-darwin/tilderef.nix
        ];
      };
      deploy.nodes.serverref = {
        hostname = generated-serverref-data-from-pulumi.ipAddress;
        profilesOrder = [ "system" ];
        profiles.system = {
          user = "root";
          sshUser = "root";
          path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.serverref;
          remoteBuild = true;
        };
      };

      formatter = forEachSystem (
        system:
        let
          pkgs = import nixpkgs-tilderef { inherit system; };
        in
        pkgs.nixfmt-rfc-style
      );

      # This is highly advised, and will prevent many possible mistakes
      # Disabled to avoid remote builder
      #checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
    };
}
