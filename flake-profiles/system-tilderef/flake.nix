{
  inputs = {
    nixpkgs-tilderef.url = "github:NixOS/nixpkgs/nixos-unstable";
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs-tilderef";
    };

    systems.url = "github:nix-systems/default";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs-tilderef";
    };

    cursor-server = {
      url = "github:strickczq/nixos-cursor-server";
      inputs.nixpkgs.follows = "nixpkgs-tilderef";
    };

    dokuwiki-plugin-oauth = {
      url = "github:cosmocode/dokuwiki-plugin-oauth";
      flake = false;
    };

    dokuwiki-plugin-oauthdiscordserver = {
      url = "github:GeorgeTR1/dokuwiki-plugin-oauthdiscordserver";
      flake = false;
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
      ...
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
          {
            nixpkgs = {
              overlays = [
                (final: super: {
                  # TODO: consider moving to soup
                  dokuwiki-plugin-oauth = final.stdenv.mkDerivation {
                    name = "oauth";
                    src = inputs.dokuwiki-plugin-oauth;
                    sourceRoot = ".";
                    installPhase = "mkdir -p $out; cp -aR source/. $out/";
                  };
                  dokuwiki-plugin-oauthdiscordserver = final.stdenv.mkDerivation {
                    name = "oauthdiscordserver";
                    src = inputs.dokuwiki-plugin-oauthdiscordserver;
                    sourceRoot = ".";
                    installPhase = "mkdir -p $out; cp -aR source/. $out/";
                  };
                })
              ];
              config = import ./../../venus/app-configs/nixpkgs-config.nix; # Configures pkgs for evaluating this nixosConfiguration ("buildtime" config)
            };
          }
          cursor-server.nixosModules.default
          ./../../venus/modules/nixos-darwin/tilderef.nix
          inputs.sops-nix.nixosModules.sops
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
