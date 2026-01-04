{ stdenv, fetchFromGitHub, maybe-flake-inputs, flake-lock }:
let
  node-name = flake-lock.nodes.root.inputs.jujutsu;
  locked = flake-lock.nodes.${node-name}.locked;
  jujutsu = if builtins.isNull maybe-flake-inputs
    then
      import (fetchFromGitHub {
        owner = locked.owner;
        repo = locked.repo;
        rev = locked.rev;
        hash = locked.narHash;
      })
    else
      maybe-flake-inputs.jujutsu.packages.${stdenv.hostPlatform.system}.default;
in
jujutsu