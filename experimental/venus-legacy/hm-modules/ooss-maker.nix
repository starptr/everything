{
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ./venus-location.nix
  ];
  options = {
    venus.ooss-maker-for-this-system = lib.mkOption {
      default = config.lib.file.mkOOSS-never;
      type = lib.types.anything;
      description = ''
        Set the function that will generate the OOSS given a path relative to hot-files.
        This option applies to this (current) configuration.
      '';
    };
  };
  config =
    let
      ooss-maker =
        hot-files-path:
        (
          #assert lib.assertMsg (builtins.isString hot-files-path) "hot-files-path must be a string"; # This doesn't print out the trace at all
          assert builtins.isString hot-files-path;
          (
            hot-file-relpath:
            assert builtins.isString hot-file-relpath;
            let
              # This is the path to the hot file
              hot-file-abspath = "${hot-files-path}/${hot-file-relpath}";
            in
            # TODO: figure out how to convert the return code of the command to a Boolean
            #assert (pkgs.runCommandLocal "" {} ''test -f ${lib.escapeShellArg hot-file-abspath}'');
            config.lib.file.mkOutOfStoreSymlink hot-file-abspath
          )
        );
    in
    {
      lib.file.mkOOSS-Sodium = ooss-maker "${config.venus-location.sodium}/hot-files";
      lib.file.mkOOSS-Tilderef2-starptr = ooss-maker "${config.venus-location.tilderef2-starptr}/hot-files";
      lib.file.mkOOSS-never = hot-files-path: builtins.throw "This is a placeholder mkOOSS function. Please override it with eg. config.lib.file.mkOOSS-Sodium.";
      lib.file.mkOOSS-Magnesium-Hydroxide = ooss-maker "${config.venus-location.magnesium-hydroxide}/hot-files";
      lib.file.mkOOSS-Hydrogen-Sulfide = ooss-maker "${config.venus-location.hydrogen-sulfide}/hot-files";
    };
}
