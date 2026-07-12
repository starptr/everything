# Bash-snippet builders shared by runners, run at launch time (idempotent).
# All snippets assume the launcher has already exported $INSTANCE_DIR and created it.
# `destExpr` args are shell expressions (may reference runtime vars like $MC), which
# Nix splices verbatim into the emitted bash.
{ pkgs, lib }:
{
  # Ensure a directory (shell expression) exists.
  ensureDir = destExpr: ''mkdir -p "${destExpr}"'';

  # Copy a store file to dest only if dest is absent — seeds a default the user/GUI
  # may then mutate freely without being clobbered on the next launch.
  seedIfAbsent = src: destExpr: ''
    [ -e "${destExpr}" ] || { cp ${src} "${destExpr}"; chmod u+w "${destExpr}"; }
  '';

  # Always overwrite dest from a store file — for content we fully manage.
  writeManaged = src: destExpr: ''
    cp -f ${src} "${destExpr}"; chmod u+w "${destExpr}"
  '';
}
