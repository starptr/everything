{ stdenv, lib, fetchFromGitHub, maybe-flake-inputs, flake-lock }:
let
  node-name = flake-lock.nodes.root.inputs.dark-notify;
  locked = flake-lock.nodes.${node-name}.locked;
  dark-notify = if builtins.isNull maybe-flake-inputs
    then
      import (fetchFromGitHub {
        owner = locked.owner;
        repo = locked.repo;
        rev = locked.rev;
        hash = locked.narHash;
      })
    else
      maybe-flake-inputs.dark-notify.packages.${stdenv.hostPlatform.system}.default;
in
dark-notify