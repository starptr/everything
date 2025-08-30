# Testing flake-parts
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    devenv.url = "github:cachix/devenv";
    devenv.inputs.nixpkgs.follows = "nixpkgs";
  };
  nixConfig = {
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
    extra-substituters = [
      "https://devenv.cachix.org"
      "https://nix-community.cachix.org"
    ];
  };
  outputs = inputs@{ flake-parts, ... }:
  # https://flake.parts/module-arguments.html
  flake-parts.lib.mkFlake { inherit inputs; } (top@{ config, withSystem, moduleWithSystem, ... }: {
    imports = [
      # Optional: use external flake logic, e.g.
      inputs.devenv.flakeModule
    ];
    flake = {
      # Put your original flake attributes here.
    };
    systems = [
      # systems for which you want to build the `perSystem` attributes
      "x86_64-linux"
      "aarch64-darwin"
    ];
    perSystem = { config, pkgs, ... }: {
      # Recommended: move all package definitions here.
      # e.g. (assuming you have a nixpkgs input)
      # packages.foo = pkgs.callPackage ./foo/package.nix { };
      # packages.bar = pkgs.callPackage ./bar/package.nix {
      #   foo = config.packages.foo;
      # };
      packages = {
        hello = pkgs.hello;
        sops = pkgs.sops;
        ssh-to-age = pkgs.ssh-to-age;
        pulumi-bin = pkgs.pulumi-bin;
      };

      devenv.shells = {
        everything-dev = {
          packages = [
            config.packages.hello
            config.packages.sops
            config.packages.ssh-to-age
          ];

          enterShell = ''
            hello
            echo "Reminder: Do not use git in this repo. Use jujutsu instead."
            echo "Don't forget to run `jj new` before making a new change."
          '';

          processes.hello.exec = "hello";

          languages.nix.enable = true;
        };
        jupiter = {
          packages = [
            config.packages.hello
            config.packages.pulumi-bin
          ];
          enterShell = ''
            hello
          '';
        };
      };

      devShells.default = config.devShells.everything-dev;
    };
  });
}