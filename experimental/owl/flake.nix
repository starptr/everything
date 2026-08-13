{
  description = "owl: turn a code checkout into a browsable static site";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    # The Rust fileset pre-filter, now its own general-purpose flake next door. owl
    # consumes only its compiled binary (in filterTree + the run scripts), so a path
    # input beats a Cargo dependency — owl keeps no Rust of its own.
    fileset = {
      url = "path:../fileset";
      inputs.nixpkgs.follows = "nixpkgs";
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
      flake-utils,
      fileset,
      everything,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;

        # The fileset pre-filter binary, built by the sibling `fileset` flake.
        filterBin = fileset.packages.${system}.default;

        # --- owl-render: the Astro renderer as a runtime binary ------------------
        # buildNpmPackage materializes node_modules from the lock but does NOT run
        # `astro build` (dontNpmBuild); we install the whole package (node_modules +
        # source) and wrap scripts/owl-render.mjs as `owl-render <tree> <out>`. The
        # tree is a RUNTIME argument, so one artifact renders any tree — and with
        # `--incremental` + a persistent `--work-dir`, re-invoking on a changed tree
        # re-renders only the changed pages. `--ignore-scripts` keeps npm ci hermetic
        # (esbuild/sharp ship prebuilt platform packages via the lock, so there is no
        # postinstall fetch).
        owl-render = pkgs.buildNpmPackage {
          pname = "owl-render";
          version = "0.1.0";
          src = ./web;

          # Hash of the npm dependency cache. Regenerate when web/package-lock.json
          # changes: `nix run nixpkgs#prefetch-npm-deps -- web/package-lock.json`.
          npmDepsHash = "sha256-NaNb/EL+NEUgGxu8ObCI2kiIMfo6gn1ip08REITlgeI=";

          npmFlags = [ "--ignore-scripts" ];
          dontNpmBuild = true; # `astro build` runs at runtime, over the given tree

          nativeBuildInputs = [ pkgs.makeWrapper ];
          env.ASTRO_TELEMETRY_DISABLED = "1";

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/libexec"
            cp -r . "$out/libexec/owl-web"
            makeWrapper ${pkgs.nodejs}/bin/node "$out/bin/owl-render" \
              --add-flags "$out/libexec/owl-web/scripts/owl-render.mjs" \
              --set ASTRO_TELEMETRY_DISABLED 1
            runHook postInstall
          '';
        };

        # --- render a pre-filtered tree to a static site (hermetic, FULL build) --
        # A thin wrapper over the owl-render binary with NO --incremental, so the
        # offline artifact is always a complete from-scratch render (owl.fileset.txt is
        # already applied to `tree`; owl-render does no filtering). owl-render
        # materializes its own writable work dir since the store is read-only.
        renderTree =
          {
            tree,
            title ? "owl",
          }:
          pkgs.runCommand "owl-web" { } ''
            ${owl-render}/bin/owl-render ${tree} "$out" --title ${lib.escapeShellArg title}
          '';

        # --- compose: filter a checkout, then render the pruned tree -------------
        # filterTree runs the fileset binary over `src` using `fileset` (the manifest,
        # which shadows the flake input of the same name here), producing a tree with
        # excluded paths (e.g. secrets/) removed — the ONLY thing the render sandbox sees.
        filterTree =
          {
            src,
            fileset,
          }:
          pkgs.runCommand "owl-filtered" { } ''
            ${filterBin}/bin/fileset --fileset ${fileset} ${src} "$out"
          '';

        renderCheckout =
          {
            src,
            fileset ? "${src}/owl.fileset.txt",
            title ? "owl",
          }:
          renderTree {
            tree = filterTree { inherit src fileset; };
            inherit title;
          };
      in
      {
        packages = {
          default = owl-render;
          inherit owl-render;

          # The whole monorepo rendered to a static site (result/ is the deployable
          # dir). Renders the COMMITTED tree of the `everything` input, so commit
          # changes first. Point at a different checkout without editing the lock:
          #   nix build .#site --override-input everything git+file:///path/to/repo
          site = renderCheckout {
            src = everything;
            title = "everything";
          };
        };

        apps.default = flake-utils.lib.mkApp {
          drv = owl-render;
        };

        # Composition helpers for consumers (e.g. a top-level flake) that have a
        # checkout as a store path and want the finished static site.
        lib = {
          inherit filterTree renderTree renderCheckout;
        };

        devShells.default = pkgs.mkShell {
          # owl has no Rust of its own now (the filter moved to the `fileset` flake);
          # just Node for the owl-web dev loop.
          packages = [ pkgs.nodejs ];
        };
      }
    );
}
