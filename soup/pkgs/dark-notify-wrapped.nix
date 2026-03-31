{ stdenv, lib, fetchFromGitHub, maybe-flake-inputs, flake-lock }:
let
  node-name = flake-lock.nodes.root.inputs.dark-notify-wrapped;
  locked = flake-lock.nodes.${node-name}.locked;
  dark-notify-wrapped = if builtins.isNull maybe-flake-inputs
    then
      import (fetchFromGitHub {
        owner = locked.owner;
        repo = locked.repo;
        rev = locked.rev;
        hash = locked.narHash;
      })
    else
      maybe-flake-inputs.dark-notify-wrapped.packages.${stdenv.hostPlatform.system}.default;
in
dark-notify-wrapped