{ self, nixpkgs, systems, ... } @ inputs: let
  forEachSystem = nixpkgs.lib.genAttrs (import systems);
in {
  packages = forEachSystem (system: let
    pkgs = nixpkgs.legacyPackages.${system};
    octodns-config = pkgs.callPackage ./octodns-config.nix {};
    octodns = pkgs.octodns.withProviders (ps: [
      pkgs.octodns-providers.cloudflare
    ]);
  in {
    eight-configurations = octodns-config.config-directory;
    eight-dry-run = pkgs.writeShellScriptBin "dry-run" ''
      cd ${octodns-config.config-directory} # CWD must be the directory containing the config files
      ${octodns}/bin/octodns-sync --config-file ${octodns-config.config-directory}/production.yaml
    '';
    eight-wet-run = pkgs.writeShellScriptBin "wet-run" ''
      cd ${octodns-config.config-directory} # CWD must be the directory containing the config files
      ${octodns}/bin/octodns-sync --config-file ${octodns-config.config-directory}/production.yaml --doit
    '';
  });
}