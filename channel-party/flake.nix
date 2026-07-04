{
  description = "channel-party: an extensibility-first, headless Discord-inspired chat platform";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane.url = "github:ipetkov/crane";

    flake-utils.url = "github:numtide/flake-utils";

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
      flake-utils,
      advisory-db,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;

        craneLib = crane.mkLib pkgs;

        # Keep migration .sql files in the build source: cleanCargoSource strips non-Rust files and
        # `include_str!("../migrations/...")` (cp-core + the discord/canvas kinds) would then fail
        # to compile. Same asset-filter concern as andref-ipfs-depot.
        src = lib.cleanSourceWith {
          src = ./.;
          name = "source";
          filter =
            path: type:
            (lib.hasSuffix ".sql" path) || (craneLib.filterCargoSources path type);
        };

        commonArgs = {
          inherit src;
          pname = "channel-party";
          version = "0.1.0";
          strictDeps = true;

          # sqlx bundles SQLite (compiled by cc from stdenv); cmake/perl are only needed if a
          # transitive rustls/ring path is pulled — harmless to provide.
          nativeBuildInputs = [
            pkgs.cmake
            pkgs.perl
          ];

          buildInputs = lib.optionals pkgs.stdenv.isDarwin [
            pkgs.libiconv
          ];

          # No compile-time-checked queries yet, so this is a no-op today; it is set now because §6
          # (type-owned index tables) and the store implementation will add `query!` macros that
          # require a committed `.sqlx` offline cache under Nix. See DESIGN §11.
          SQLX_OFFLINE = "1";
        };

        # Build the workspace dependencies once, reused by the package and every check.
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # The server binary (`channel-party`, from cp-bin) — the whole workspace as one graph.
        server = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts;
          }
        );

        # The Astro frontend, built with npm (buildNpmPackage) as a Nix derivation. The island
        # registry is generated at build time from kinds/*/web (web/scripts/gen-registry.mjs).
        # See DESIGN §9/§11. (§11 lists buildNpmPackage/pnpm; the pnpm fetcher SIGKILLs on exit in
        # the Nix builder here, so npm is used.)
        #
        # The source keeps the Astro app (web/) and the island sources the registry scans
        # (kinds/*/web); the npm package is the web/ subdirectory.
        webSrc = lib.cleanSourceWith {
          src = ./.;
          name = "channel-party-web-src";
          filter =
            path: _type:
            let
              rel = lib.removePrefix (toString ./. + "/") (toString path);
            in
            rel == "web" || (lib.hasPrefix "web/" rel) || (builtins.match "kinds/[^/]+/web(/.*)?" rel != null);
        };

        web = pkgs.buildNpmPackage (finalAttrs: {
          pname = "channel-party-web";
          version = "0.1.0";
          src = webSrc;
          # The npm package is web/; its build reaches ../kinds/*/web (kept in webSrc) to generate
          # the island registry. buildNpmPackage passes sourceRoot to its internal fetchNpmDeps too.
          sourceRoot = "${finalAttrs.src.name}/web";

          # Hash of the npm dependency cache. Regenerate with `lib.fakeHash` if package-lock.json
          # changes: `nix build ./channel-party#web` then copy the reported hash here.
          npmDepsHash = "sha256-n/HrVd2jXMZbW0R4sE86XGV0a8nn2K6ceqvcsbBx4WQ=";

          # Skip dependency lifecycle scripts: esbuild ships prebuilt binaries, and sharp — unused,
          # since astro.config.mjs selects the passthrough image service — would otherwise fetch
          # libvips over the network at build time. `npm run build` (gen-registry + astro build)
          # produces web/dist.
          npmFlags = [ "--ignore-scripts" ];

          env.ASTRO_TELEMETRY_DISABLED = "1";

          installPhase = ''
            runHook preInstall
            cp -r dist "$out"
            runHook postInstall
          '';
        });

        # The shipped package: the server binary wrapped to serve the bundled static build. §11.
        channel-party = pkgs.runCommand "channel-party"
          {
            pname = "channel-party";
            version = "0.1.0";
            nativeBuildInputs = [ pkgs.makeWrapper ];
          }
          ''
            mkdir -p "$out/bin" "$out/share/channel-party/web"
            cp -r ${web}/* "$out/share/channel-party/web/"
            makeWrapper ${server}/bin/channel-party "$out/bin/channel-party" \
              --set-default CP_WEB_DIR "$out/share/channel-party/web"
          '';
      in
      {
        checks = {
          inherit server web;

          clippy = craneLib.cargoClippy (
            commonArgs
            // {
              inherit cargoArtifacts;
              cargoClippyExtraArgs = "--all-targets -- --deny warnings";
            }
          );

          doc = craneLib.cargoDoc (
            commonArgs
            // {
              inherit cargoArtifacts;
              env.RUSTDOCFLAGS = "--deny warnings";
            }
          );

          fmt = craneLib.cargoFmt { inherit src; };

          toml-fmt = craneLib.taploFmt {
            src = lib.sources.sourceFilesBySuffices src [ ".toml" ];
          };

          audit = craneLib.cargoAudit { inherit src advisory-db; };

          deny = craneLib.cargoDeny { inherit src; };

          nextest = craneLib.cargoNextest (
            commonArgs
            // {
              inherit cargoArtifacts;
              partitions = 1;
              partitionType = "count";
              cargoNextestPartitionsExtraArgs = "--no-tests=pass";
            }
          );
        };

        packages = {
          default = channel-party;
          inherit server web;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = channel-party;
        }
        // {
          meta.description = "Run the channel-party server (serves the bundled Astro frontend).";
        };

        devShells.default = craneLib.devShell {
          # cargo + rustc are provided by craneLib; add the frontend (Node/npm) + sqlx toolchain.
          # DESIGN §11 (npm rather than pnpm — see the web derivation comment).
          packages = [
            pkgs.nodejs
            pkgs.sqlx-cli
          ];
        };
      }
    );
}
