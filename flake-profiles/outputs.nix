{
  self,
  ...
} @ inputs:
let
  # Define common variables
  forEachSystem = inputs.nixpkgs.lib.genAttrs (import inputs.systems);
in
{
  devShells = forEachSystem (system:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
    in
    {
      default = inputs.devenv.lib.mkShell {
        inherit inputs pkgs;
        modules = [
          {
            # https://devenv.sh/reference/options/
            packages = [
              pkgs.hello
              pkgs.sops
              pkgs.ssh-to-age
            ];

            enterShell = ''
              hello
              echo "Reminder: Do not use git in this repo. Use jujutsu instead."
            '';

            processes.hello.exec = "hello";

            languages.nix.enable = true;
          }
        ];
      };
    });

  darwinConfigurations."Yutos-Sodium" = inputs.nix-darwin.lib.darwinSystem {
    system = "aarch64-darwin";
    modules = [
      ../venus/modules/nixos-darwin/sodium.nix
      inputs.home-manager.darwinModules.home-manager
      {
        nixpkgs = {
          overlays = [
            (self: super: {
              jellyfin-mpv-shim = inputs.jellyfin-mpv-shim-darwin.packages."aarch64-darwin".default;
            })
            #chaseln.overlays.chaseln
            inputs.soup.overlays.chaseln
            (final: super: {
              check-gits = inputs.soup.legacyPackages."aarch64-darwin".check-gits;
            })
          ];
          config = import ../venus/app-configs/nixpkgs-config.nix; # Configures pkgs for evaluating this darwinConfiguration ("buildtime" config)
        };
      }
      {
        home-manager.useGlobalPkgs = true;
        #home-manager.useUserPackages = true; # This breaks fish??
        home-manager.users.yuto = {
          imports = [
            inputs.sops-nix.homeManagerModules.sops
            (import ../venus/modules/home-manager/sodium.nix)
          ];
        };
        home-manager.extraSpecialArgs = {
          inherit (inputs) nixpkgs;
        };
      }
    ];
  };
}