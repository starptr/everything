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
}