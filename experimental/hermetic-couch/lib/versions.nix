# Version/compat validation (DESIGN §4). Given the declared captures, the selected
# `play` version, and a per-game compat contract, produce module `assertions` and the
# selected snapshot. Lightweight here; the requireFile/buildid capture path is Part 4.
{ pkgs, lib }:
{
  versions ? { },
  play ? null,
  compat ? { },
}:
let
  min = compat.min or null;
  max = compat.max or null;
  known = compat.known or null;

  assertions = lib.optionals (play != null) (
    lib.optional (versions != { } && !(versions ? ${play})) {
      assertion = false;
      message = "hermetic-couch: no captured snapshot for version ${play}";
    }
    ++ lib.optional (min != null) {
      assertion = lib.versionAtLeast play min;
      message = "hermetic-couch: version ${play} is below minimum supported ${min}";
    }
    ++ lib.optional (max != null) {
      assertion = !(lib.versionOlder max play);
      message = "hermetic-couch: version ${play} exceeds tested maximum ${max}";
    }
    ++ lib.optional (known != null) {
      assertion = lib.elem play known;
      message = "hermetic-couch: version ${play} not in known-good set ${toString known}";
    }
  );

  selected = if (play != null && versions ? ${play}) then versions.${play} else null;
in
{
  inherit assertions selected;
}
