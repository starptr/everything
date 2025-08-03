{ config, lib, ... }:
{
  # This file contains the single-source-of-truth for the location of the venus repository.
  options = {
    venus-location.sodium = lib.mkOption {
      readOnly = true;
      default = "${config.home.homeDirectory}/src/venus";
      type = lib.types.str;
      description = ''
        The location of the venus repository.
      '';
    };
    venus-location.tilderef2-starptr = lib.mkOption {
      readOnly = true;
      default = "${config.home.homeDirectory}/src/venus";
      type = lib.types.str;
      description = ''
        The location of the venus repository for the starptr profile on tilderef2.
      '';
    };
    venus-location.magnesium-hydroxide = lib.mkOption {
      readOnly = true;
      default = "${config.home.homeDirectory}/src/venus";
      type = lib.types.str;
      description = ''
        The location of the venus repository for the starptr profile on magnesium-hydroxide.
      '';
    };
    venus-location.hydrogen-sulfide = lib.mkOption {
      readOnly = true;
      default = "${config.home.homeDirectory}/src/venus";
      type = lib.types.str;
      description = ''
        The location of the venus repository for the starptr profile on hydrogen-sulfide.
      '';
    };
  };
}
