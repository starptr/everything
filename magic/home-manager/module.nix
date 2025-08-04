{ config, lib, ... } @ inputs:
let
  constants = import ./constants.nix (inputs);
in
{
  # This file contains the single-source-of-truth for any anonymous value, ie. magic values.
  # TODO: is this module option necessary?
  options = {
    magic = lib.mkOption {
      readOnly = true;
      default = constants;
      #type = lib.types.str;
      description = ''
        Magic constants.
      '';
    };
  };
}