{ config, lib, ... }:
{
  imports = [
    ./../../../magic/home-manager/module.nix
  ];
  # This file contains the single-source-of-truth for the location of the venus repository.
  # TODO: remove this file
  options = {
    venus-location.sodium = lib.mkOption {
      readOnly = true;
      default = config.magic.absolutePathStrings.sodium.venus;
      type = lib.types.str;
      description = ''
        The location of the venus repository.
      '';
    };
    # TODO(magic): use magic
    #venus-location.tilderef2-starptr = lib.mkOption {
    #  readOnly = true;
    #  default = "${config.home.homeDirectory}/src/everything/venus";
    #  type = lib.types.str;
    #  description = ''
    #    The location of the venus repository for the starptr profile on tilderef2.
    #  '';
    #};
    # TODO(magic): use magic
    #venus-location.magnesium-hydroxide = lib.mkOption {
    #  readOnly = true;
    #  default = "${config.home.homeDirectory}/src/everything/venus";
    #  type = lib.types.str;
    #  description = ''
    #    The location of the venus repository for the starptr profile on magnesium-hydroxide.
    #  '';
    #};
    # TODO(magic): use magic
    #venus-location.hydrogen-sulfide = lib.mkOption {
    #  readOnly = true;
    #  default = "${config.home.homeDirectory}/src/everything/venus";
    #  type = lib.types.str;
    #  description = ''
    #    The location of the venus repository for the starptr profile on hydrogen-sulfide.
    #  '';
    #};
  };
}
