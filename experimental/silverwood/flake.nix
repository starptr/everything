{
  description = "silverwood: a frontend-agnostic backend for code/agent workstreams";

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
        src = craneLib.cleanCargoSource ./.;

        commonArgs = {
          inherit src;
          pname = "silverwood";
          version = "0.1.0";
          strictDeps = true;

          buildInputs = lib.optionals pkgs.stdenv.isDarwin [
            pkgs.libiconv
          ];
        };

        # Build the workspace dependencies once, reused by the package and every check.
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # The `silverwood` CLI binary (whole workspace built as one graph).
        # Part 1 will wrap this with `jujutsu` + `git` on PATH once checkout
        # provisioning shells out to `jj git clone --colocate`.
        silverwood = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts;
            meta.mainProgram = "silverwood";
          }
        );
      in
      {
        checks = {
          inherit silverwood;

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

        packages.default = silverwood;

        apps.default = flake-utils.lib.mkApp {
          drv = silverwood;
        }
        // {
          meta.description = "Run the silverwood CLI.";
        };

        devShells.default = craneLib.devShell {
          # cargo + rustc + clippy + rustfmt come from craneLib; add jj/git (Part 1
          # provisioning) and taplo (toml formatting used by the toml-fmt check).
          packages = [
            pkgs.jujutsu
            pkgs.git
            pkgs.taplo
          ];
        };
      }
    );
}
