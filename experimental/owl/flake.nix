{
  description = "owl: turn a code checkout into a browsable static site";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane.url = "github:ipetkov/crane";

    flake-utils.url = "github:numtide/flake-utils";

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };

    # The monorepo itself, as a plain source tree (the repo root has no flake.nix),
    # so `packages.site` can render it. flake = false → just the git-tracked files,
    # so .gitignore is respected and node_modules/.direnv never enter the store.
    # Absolute path matches soup's silverwood/papyrus inputs.
    everything = {
      url = "git+file:///Users/yuto/src/everything";
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
      everything,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;

        craneLib = crane.mkLib pkgs;

        # --- owl-filter: the Rust fileset pre-filter (crate in ./filter) ---------
        # Pure-Rust deps (globset/walkdir/clap/anyhow), so no cmake/perl; libiconv
        # only for the darwin linker.
        filterSrc = craneLib.cleanCargoSource ./filter;
        filterArgs = {
          src = filterSrc;
          strictDeps = true;
          buildInputs = lib.optionals pkgs.stdenv.isDarwin [ pkgs.libiconv ];
        };
        filterDeps = craneLib.buildDepsOnly filterArgs;
        owl-filter = craneLib.buildPackage (filterArgs // { cargoArtifacts = filterDeps; });

        # --- owl-web: the Astro renderer, parameterized by the pre-filtered tree --
        # buildNpmPackage runs `npm run build` (gen-manifest + astro build). The
        # tree to render is handed in via OWL_INPUT_DIR; owl-web does no filtering.
        # `--ignore-scripts` + passthrough image service keep the build hermetic
        # (no sharp/libvips fetch), matching channel-party/web.
        renderTree =
          tree:
          pkgs.buildNpmPackage {
            pname = "owl-web";
            version = "0.1.0";
            src = ./web;

            # Hash of the npm dependency cache. Regenerate when web/package-lock.json
            # changes: `nix run nixpkgs#prefetch-npm-deps -- web/package-lock.json`.
            npmDepsHash = "sha256-NwZDqIBtC+fd6uHA1vcC04YDD386jfpY7MQD/qYSsUY=";

            npmFlags = [ "--ignore-scripts" ];

            env = {
              ASTRO_TELEMETRY_DISABLED = "1";
              # Coerce to a store-path string: buildNpmPackage's `env` rejects path values.
              OWL_INPUT_DIR = "${tree}";
            };

            installPhase = ''
              runHook preInstall
              cp -r dist "$out"
              runHook postInstall
            '';
          };

        # --- compose: filter a checkout, then render the pruned tree -------------
        # filterTree runs owl-filter over `src` using `fileset`, producing a tree
        # with excluded paths (e.g. secrets/) removed — that tree is the ONLY thing
        # the render sandbox sees.
        filterTree =
          {
            src,
            fileset,
          }:
          pkgs.runCommand "owl-filtered" { } ''
            ${owl-filter}/bin/owl-filter --fileset ${fileset} ${src} "$out"
          '';

        renderCheckout =
          {
            src,
            fileset ? "${src}/owl.fileset.txt",
          }:
          renderTree (filterTree { inherit src fileset; });
      in
      {
        packages = {
          default = owl-filter;
          inherit owl-filter;

          # The whole monorepo rendered to a static site (result/ is the deployable
          # dir). Renders the COMMITTED tree of the `everything` input, so commit
          # changes first. Point at a different checkout without editing the lock:
          #   nix build .#site --override-input everything git+file:///path/to/repo
          site = renderCheckout { src = everything; };
        };

        apps.default = flake-utils.lib.mkApp {
          drv = owl-filter;
        };

        # Composition helpers for consumers (e.g. a top-level flake) that have a
        # checkout as a store path and want the finished static site.
        lib = {
          inherit filterTree renderTree renderCheckout;
        };

        checks = {
          inherit owl-filter;

          owl-filter-clippy = craneLib.cargoClippy (
            filterArgs
            // {
              cargoArtifacts = filterDeps;
              cargoClippyExtraArgs = "--all-targets -- --deny warnings";
            }
          );

          owl-filter-fmt = craneLib.cargoFmt { src = filterSrc; };

          owl-filter-audit = craneLib.cargoAudit { src = filterSrc; inherit advisory-db; };

          owl-filter-nextest = craneLib.cargoNextest (
            filterArgs
            // {
              cargoArtifacts = filterDeps;
              partitions = 1;
              partitionType = "count";
              cargoNextestPartitionsExtraArgs = "--no-tests=pass";
            }
          );
        };

        devShells.default = craneLib.devShell {
          # cargo + rustc come from craneLib; add Node for the owl-web dev loop.
          packages = [ pkgs.nodejs ];
        };
      }
    );
}
