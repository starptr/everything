{ stdenv, fetchFromGitHub, maybe-flake-inputs, flake-lock }:
let
  node-name = flake-lock.nodes.root.inputs.chaseln;
  locked = flake-lock.nodes.${node-name}.locked;
  chaseln = if builtins.isNull maybe-flake-inputs
    then
      import (fetchFromGitHub {
        owner = locked.owner;
        repo = locked.repo;
        rev = locked.rev;
        hash = locked.narHash;
      })
    else
      maybe-flake-inputs.chaseln.packages.${stdenv.hostPlatform.system}.default;
in
chaseln