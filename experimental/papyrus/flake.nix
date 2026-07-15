{
  description = "papyrus — a canvas GUI frontend for silverwood workstreams (vendored from Fallomai/openui)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    # Bun-native packaging. Consumes the project's real bun.lock (via committed
    # bun.nix) and keeps a real node_modules, so bun-pty's FFI .dylib still
    # dlopens at runtime — a `bun build --compile` single binary breaks it
    # (Bun #30717). See VENDOR.md. (bun2nix is a small Rust tool built from
    # source unless its nix-community cachix cache is a trusted substituter.)
    bun2nix.url = "github:nix-community/bun2nix?ref=2.1.1";
    bun2nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      bun2nix,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib stdenv;

        # bun2nix's builders (writeBunApplication / mkDerivation / fetchBunDeps /
        # hook) are exposed as passthru on its default package.
        b2n = bun2nix.packages.${system}.default;

        # The Vite/React client, built to static `dist`. Pure JS (no native
        # modules); installed + built with bun from client/bun.nix.
        client = b2n.mkDerivation {
          pname = "papyrus-client";
          version = "1.2.1";
          src = ./client;
          bunDeps = b2n.fetchBunDeps { bunNix = ./client/bun.nix; };
          buildPhase = "bun run build"; # package.json build: tsc && vite build -> dist
          installPhase = ''
            runHook preInstall
            cp -r dist "$out"
            runHook postInstall
          '';
        };

        # The Bun server, packaged as a runnable app that keeps its real
        # node_modules (bun-pty's native .dylib must dlopen at runtime). There is
        # no bundle/compile step — Bun executes the TypeScript directly.
        papyrus = b2n.writeBunApplication {
          packageJson = ./package.json; # -> pname "papyrus" + version
          src = ./.;
          bunDeps = b2n.fetchBunDeps { bunNix = ./bun.nix; };

          # No `bun build`: run server/index.ts as-is. Also makes dontFixup
          # default true (no buildPhase), so the .dylib is never stripped.
          dontUseBunBuild = true;

          # Keep bun-pty's per-platform prebuilt binary; darwin wants symlinks.
          bunInstallFlags = [
            "--cpu=*"
          ]
          ++ lib.optionals (stdenv.hostPlatform.system != "x86_64-linux") [
            "--linker=isolated"
            "--backend=symlink"
          ];

          startScript = "bun run server/index.ts";

          # writeBunApplication's wrapper --chdir's into $out/share/papyrus at
          # runtime, so server/index.ts's `serveStatic({ root: "./client/dist" })`
          # resolves there — place the built client accordingly. Then re-wrap so
          # the user's launch dir is captured into LAUNCH_CWD *before* that chdir
          # (persistence writes `.openui/` under LAUNCH_CWD, which must be the
          # user's pwd, not the read-only store). See VENDOR.md.
          postInstall = ''
            cp -r ${client} "$out/share/papyrus/client/dist"

            mv "$out/bin/papyrus" "$out/bin/.papyrus-inner"
            makeWrapper "$out/bin/.papyrus-inner" "$out/bin/papyrus" \
              --run 'export LAUNCH_CWD="''${LAUNCH_CWD:-$PWD}"'
          '';
        };
      in
      {
        packages = {
          default = papyrus;
          inherit client;
        };

        checks = {
          inherit client;
          papyrus = papyrus;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = papyrus;
        }
        // {
          meta.description = "Run the papyrus server (serves the bundled canvas UI on :6968).";
        };

        devShells.default = pkgs.mkShell {
          # bun for dev (`bun install && bun run dev`); bun2nix regenerates bun.nix.
          packages = [
            pkgs.bun
            b2n
          ];
        };
      }
    );
}
