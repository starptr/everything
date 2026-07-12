# java runner — HERMETIC Minecraft launch. The entire game payload (client, libraries,
# natives, assets, loader) is a single content-addressed store path (pkgs/minecraft-
# payload.nix); portablemc launches directly from it OFFLINE (`--fetch-exclude-all`, a
# read-only store `--main-dir`), writing only mutable game state (saves/mods/logs/token)
# into the instance dir. Nothing but the Microsoft OAuth token — an irreducible per-user
# secret — is provisioned at runtime.
#
# runnerConfig = {
#   minecraft :: str;                       # e.g. "1.21.1"
#   loader = { kind = "fabric"|"quilt"|"vanilla"; version :: str; };
#   jre :: derivation;                      # e.g. pkgs.temurin-bin-21
#   payloadHash :: str;                     # sha256 of the pinned payload (see minecraft-payload.nix)
#   mods = [ derivation ];                  # jars, symlinked into <instanceDir>/mods/
#   username ? null;                        # optional MS username to disambiguate -a
# }
{ pkgs, lib, hcLib }:
spec:
let
  cfg = spec.runnerConfig;
  portablemc = pkgs.portablemc;
  jre = cfg.jre;
  mods = cfg.mods or [ ];
  loaderKind = cfg.loader.kind or "vanilla";

  payload = pkgs.callPackage ../pkgs/minecraft-payload.nix { } {
    inherit (cfg) minecraft loader jre;
    hash = cfg.payloadHash;
  };

  # The local (already-installed) version id to launch, so no manifest/loader API is
  # contacted: portablemc names Fabric versions "fabric-<mc>-<loader>".
  localVersionId =
    if loaderKind == "vanilla" then
      cfg.minecraft
    else
      "${loaderKind}-${cfg.minecraft}-${cfg.loader.version}";

  msaFile = ''"$INSTANCE_DIR/portablemc_msa.json"'';

  username = cfg.username or null;
  # portablemc's -a needs an explicit account selector; -a alone errors. Prefer a
  # declared username, else auto-detect the logged-in account's UUID at launch.
  authSetup = lib.optionalString (username == null) ''
    HC_MC_UUID="$(portablemc --msa-db-file ${msaFile} auth list 2>/dev/null | grep -oiE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' | head -n1 || true)"
    if [ -z "$HC_MC_UUID" ]; then
      echo "hermetic-couch: no authenticated account found; re-run to log in, or set runnerConfig.username" >&2
      exit 1
    fi
  '';
  authFlag =
    if username != null then "-a -u ${lib.escapeShellArg username}" else ''-a -i "$HC_MC_UUID"'';

  renderOpt = k: v: "${k}:${if lib.isBool v then lib.boolToString v else toString v}";
  optionsTxt = pkgs.writeText "options.txt" (
    lib.concatStringsSep "\n" (lib.mapAttrsToList renderOpt (spec.settings or { })) + "\n"
  );

  linkMods = lib.concatMapStringsSep "\n" (m: ''
    ln -sfn ${m} "$INSTANCE_DIR/mods/${m.name}"
    echo ${lib.escapeShellArg m.name} >> "$INSTANCE_DIR/.hc-managed-mods"
  '') mods;
in
{
  package = payload;
  runtimeInputs = [ portablemc ];

  reconcile = ''
    mkdir -p "$INSTANCE_DIR/mods" "$INSTANCE_DIR/bin"

    # Managed mods: drop the previously-linked set, then relink the current pins so a
    # version bump swaps cleanly. The user's own hand-added mods are left untouched.
    if [ -f "$INSTANCE_DIR/.hc-managed-mods" ]; then
      while IFS= read -r f; do [ -n "$f" ] && rm -f "$INSTANCE_DIR/mods/$f"; done < "$INSTANCE_DIR/.hc-managed-mods"
    fi
    : > "$INSTANCE_DIR/.hc-managed-mods"
    ${linkMods}

    ${hcLib.reconcile.seedIfAbsent optionsTxt "$INSTANCE_DIR/options.txt"}

    # One-time interactive Microsoft login; the session token is cached in the mutable
    # instance dir, never in the store.
    if [ ! -s ${msaFile} ]; then
      echo "hermetic-couch: first run — logging into your Microsoft account (one-time)…"
      portablemc --msa-db-file ${msaFile} auth login
    fi
    ${authSetup}
  '';

  # Offline launch from the read-only store payload (main-dir); all mutable game state
  # lives under the instance dir (mc-dir / bin-dir / msa).
  launchCmd = ''
    portablemc start --main-dir ${payload} --mc-dir "$INSTANCE_DIR" --bin-dir "$INSTANCE_DIR/bin" --msa-db-file ${msaFile} --fetch-exclude-all --jvm ${jre}/bin/java ${authFlag} ${localVersionId}'';
}
