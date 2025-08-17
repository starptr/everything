{ stdenv, lib, fetchFromGitHub, maybe-flake-inputs, flake-lock }:
let
  node-name = flake-lock.nodes.root.inputs.check-gits;
  locked = flake-lock.nodes.${node-name}.locked;
  check-gits = if builtins.isNull maybe-flake-inputs
    then
      import (fetchFromGitHub {
        owner = locked.owner;
        repo = locked.repo;
        rev = locked.rev;
        hash = locked.narHash;
      })
    else
      maybe-flake-inputs.check-gits.packages.${stdenv.hostPlatform.system}.default;
in
check-gits