{
  description = "yutobot-discord: Yuto's Discord bot (welcome cards, owoifier, wii menu)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;

        # Node 22 (current Active LTS). nodejs_20 was removed from nixpkgs on its EOL; the app's
        # `canvas` dep was bumped 2.x -> 3.x to match (canvas 3 uses Node-API, so it compiles against
        # Node 22's V8, whereas the nan-based 2.x does not).
        nodejs = pkgs.nodejs_22;

        yutobot-discord = pkgs.buildNpmPackage {
          pname = "yutobot-discord";
          version = "0.2.1";
          src = ./.;
          inherit nodejs;

          # FOD hash of the npm dependency closure (derived from package-lock.json). Regenerate when
          # the lock changes: set to lib.fakeHash, build, copy the hash nix reports back here.
          npmDepsHash = "sha256-8hulg5Qm4Yf7XCru4vob2Aiv1oMTYJkC8pe3MoA4WRo=";

          # Plain CommonJS run directly on node -- there is NO transpile step. (Upstream's babel
          # "build" was a no-op: no babel config existed and the code needs no transpilation.)
          dontNpmBuild = true;

          # `canvas` is the only native dep -- it compiles cairo/pango bindings via node-gyp; force a
          # from-source build so it never depends on a (sandbox-blocked) prebuilt download.
          npm_config_build_from_source = "true";
          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.python3
            pkgs.makeWrapper
          ];
          buildInputs = [
            pkgs.cairo
            pkgs.pango
            pkgs.libpng
            pkgs.libjpeg
            pkgs.giflib
            pkgs.librsvg
            pkgs.pixman
          ];

          # buildNpmPackage installs the package tree (deps included) to
          # $out/lib/node_modules/yutobot-discord. package.json declares no `bin`, so wrap the
          # entrypoint into $out/bin/yutobot-discord on the pinned node. Assets load via __dirname
          # (the store), so the process CWD is free to hold only the mounted .env.
          postInstall = ''
            makeWrapper ${nodejs}/bin/node $out/bin/yutobot-discord \
              --add-flags $out/lib/node_modules/yutobot-discord/src/index.js
          '';

          meta = {
            description = "Yuto's Discord bot";
            mainProgram = "yutobot-discord";
            license = lib.licenses.mit;
          };
        };
      in
      {
        packages.default = yutobot-discord;
        apps.default = flake-utils.lib.mkApp { drv = yutobot-discord; };
        devShells.default = pkgs.mkShell { packages = [ nodejs ]; };
      }
    );
}
