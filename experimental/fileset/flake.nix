{
  description = "fileset: filter files from a directory with a gitignore-like manifest";

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

        # Pure-Rust deps (globset/walkdir/clap/anyhow), so no cmake/perl; libiconv
        # only for the darwin linker.
        src = craneLib.cleanCargoSource ./.;
        commonArgs = {
          inherit src;
          strictDeps = true;
          buildInputs = lib.optionals pkgs.stdenv.isDarwin [ pkgs.libiconv ];
        };
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;
        fileset = craneLib.buildPackage (commonArgs // { inherit cargoArtifacts; });
      in
      {
        packages.default = fileset;
        packages.fileset = fileset;

        apps.default = flake-utils.lib.mkApp {
          drv = fileset;
        };

        checks = {
          inherit fileset;

          fileset-clippy = craneLib.cargoClippy (
            commonArgs
            // {
              inherit cargoArtifacts;
              cargoClippyExtraArgs = "--all-targets -- --deny warnings";
            }
          );

          fileset-fmt = craneLib.cargoFmt { inherit src; };

          fileset-audit = craneLib.cargoAudit { inherit src advisory-db; };

          fileset-nextest = craneLib.cargoNextest (
            commonArgs
            // {
              inherit cargoArtifacts;
              partitions = 1;
              partitionType = "count";
              cargoNextestPartitionsExtraArgs = "--no-tests=pass";
            }
          );
        };

        devShells.default = craneLib.devShell { };
      }
    );
}
