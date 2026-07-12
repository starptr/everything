# wine runner — Tier-B Windows/Steam games (DESIGN §6, §9.2), reworked around a
# hermetic capture→launch model that mirrors the java runner:
#
#   1. ENV (pinned, in store): frankea/Whisky wine + the DXMT (D3D11→Metal) dlls it
#      bundles + GUI-less winetricks (pkgs/whisky-wine.nix). Content-addressed, reproducible.
#   2. PROVISION (non-hermetic, one-time): `hc-steam-provision` boots Steam in the env so
#      you install your game; bits land in a runtime dir, never the store.
#   3. CAPTURE (non-hermetic, per-user): `hc-capture` content-addresses your install into
#      the store and prints a `versions."<v>"` stanza (Pattern B — unfree, per-user).
#   4. LAUNCH (hermetic): run the captured store payload in the env, OFFLINE, NO Steam.
#
# Steam is a capture-time tool, not a launch dependency. Launch mode is chosen by state:
#   - captured (spec.play set + spec.versions has it) → hermetic store launch. DEFAULT.
#   - not captured yet                                → a launcher that prints how to capture.
#   - runnerConfig.launchViaSteam = true             → the honest non-hermetic fallback,
#     for games whose DRM (SteamStub-encrypted exe / live ownership gate) makes a static
#     store copy unrunnable. We do NOT emulate Steam to defeat such enforcement.
#
# runnerConfig = {
#   wine ? <lib/wine-pin.nix>;                # { version; url; hash; } of the Whisky bundle
#   graphics ? "dxmt";                        # inject DXMT dlls into the prefix + force them native
#   winetricks ? [ "vcrun2022" ] | (play: […]);   # verbs, applied once (state-tracked)
#   gameFolder ? spec.gameName;               # top dir inside the payload / steamapps/common
#   exe;                                      # game exe path relative to gameFolder
#   steamAppId ? null;                        # sets SteamAppId env (lets non-enforcing steam_api init offline)
#   launchViaSteam ? false;                   # opt in to the Steam-at-launch fallback
# }
# spec.gameName :: str; spec.play :: str|null; spec.versions :: { "<v>" = { sha256; buildid; }; }
{
  pkgs,
  lib,
  hcLib,
}:
spec:
let
  cfg = spec.runnerConfig;

  winePin = cfg.wine or (import ../lib/wine-pin.nix);
  wineBundle = pkgs.callPackage ../pkgs/whisky-wine.nix { } {
    inherit (winePin) version url hash;
  };
  wineBin = "${wineBundle}/Wine/bin/wine";
  wineServer = "${wineBundle}/Wine/bin/wineserver";

  winetricksPkg = pkgs.callPackage ../pkgs/winetricks-min.nix { } (
    cfg.winetricksSrc or {
      version = "20260125";
      hash = "sha256-Qx+C/HQADmyGRAnx2PtJXWlsA5KICOPorP/EUXkxKns=";
    }
  );

  gameName = spec.gameName or spec.displayName or "game";
  play = spec.play or null;
  versions = spec.versions or { };
  captured = play != null && versions ? ${play};
  launchViaSteam = cfg.launchViaSteam or false;

  # A steamStub game renders from static files but calls Steam for a live auth token at
  # launch. The hybrid path keeps the captured store bytes and runs Steam in-prefix only
  # to mint that token (you log in once; it persists).
  needsSteamAuth = (spec.drm or "none") == "steamStub";
  buildid = if captured then ((versions.${play} or { }).buildid or "0") else "0";

  gameFolder = cfg.gameFolder or gameName;
  steamAppId = cfg.steamAppId or null;
  steamSetupUrl = "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe";
  steamExe = "C:/Program Files (x86)/Steam/steam.exe";

  graphics = cfg.graphics or "dxmt";
  # DXMT (D3D11→Metal) ships in the pinned wine bundle but is NOT installed into fresh
  # prefixes — wine's builtin d3d11 is wined3d, which can't give Unreal a Feature-Level-11
  # device. Inject DXMT's real native dlls into the prefix (overwriting wine's fakedll
  # stubs), then force them native so they beat the builtin wined3d. Idempotent.
  dxmtInject = lib.optionalString (graphics == "dxmt") ''
    _sys="$WINEPREFIX/drive_c/windows/system32"
    _wow="$WINEPREFIX/drive_c/windows/syswow64"
    cp -f ${wineBundle}/DXMT/x64/*.dll "$_sys"/ 2>/dev/null || true
    { [ -d "$_wow" ] && cp -f ${wineBundle}/DXMT/x32/*.dll "$_wow"/ 2>/dev/null; } || true
  '';
  dxmtOverrides = lib.optionalString (graphics == "dxmt") "d3d11,dxgi,d3d10core=n,b;";

  wt = cfg.winetricks or [ "vcrun2022" ];
  verbs = if lib.isFunction wt then wt play else wt;
  applyVerbs = lib.concatMapStringsSep "\n" (v: ''
    if ! grep -qxF ${lib.escapeShellArg v} "$INSTANCE_DIR/.hc-winetricks"; then
      echo "hermetic-couch: applying winetricks verb '${v}'…"
      winetricks -q -f ${lib.escapeShellArg v}
      echo ${lib.escapeShellArg v} >> "$INSTANCE_DIR/.hc-winetricks"
    fi
  '') verbs;

  payload = pkgs.callPackage ../pkgs/steam-game-payload.nix { } {
    name = gameName;
    version = play;
    sha256 = (versions.${play} or { }).sha256 or lib.fakeHash;
  };

  runtimeInputs = [
    winetricksPkg
    pkgs.curl
    pkgs.coreutils
  ];

  # Shared launch-time env + one-time prefix reconcile (wineboot + winetricks). All wine
  # state is contained under the instance dir (WINEPREFIX + XDG_CACHE_HOME).
  envAndPrefix = ''
    export WINEPREFIX="$INSTANCE_DIR/prefix"
    export XDG_CACHE_HOME="$INSTANCE_DIR/cache"
    mkdir -p "$XDG_CACHE_HOME"
    export WINE=${lib.escapeShellArg wineBin}
    export WINESERVER=${lib.escapeShellArg wineServer}
    export WINELOADER=${lib.escapeShellArg wineBin}
    export WINEARCH=win64
    export WINEDEBUG=''${WINEDEBUG:-fixme-all}
    export PATH=${lib.escapeShellArg "${wineBundle}/Wine/bin"}:"$PATH"

    if ! /usr/bin/arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
      echo "hermetic-couch: WARNING — Rosetta 2 not installed; x86 game code won't run." >&2
      echo "  Install it once with: softwareupdate --install-rosetta --agree-to-license" >&2
    fi

    if [ ! -d "$WINEPREFIX/drive_c" ]; then
      echo "hermetic-couch: initializing wine prefix (one-time)…"
      WINEDLLOVERRIDES="mscoree,mshtml=" "${wineBin}" wineboot -u
      "${wineServer}" -w
    fi

    touch "$INSTANCE_DIR/.hc-winetricks"
    ${applyVerbs}
    ${dxmtInject}
  '';

  forceDxmt = ''export WINEDLLOVERRIDES="${dxmtOverrides}''${WINEDLLOVERRIDES:-}"'';

  # One-time Steam install into the launch prefix (impure; Tier-B mutable state).
  steamInstall = ''
    if [ ! -f "$WINEPREFIX/drive_c/Program Files (x86)/Steam/steam.exe" ]; then
      echo "hermetic-couch: installing Steam into the prefix (one-time)…"
      setup="$INSTANCE_DIR/SteamSetup.exe"
      [ -f "$setup" ] || curl -fsSL -o "$setup" ${lib.escapeShellArg steamSetupUrl}
      "${wineBin}" "$setup" /S
      "${wineServer}" -w
    fi
  '';

  # --- Branch 1: hermetic launch from the captured store payload, no Steam ---
  hermetic = {
    package = payload;
    inherit runtimeInputs;
    reconcile = ''
      ${envAndPrefix}

      # Expose the read-only store payload (the game dir itself) at the path the game
      # expects, via a symlink — bytes stay content-addressed in the store; only the
      # prefix is mutable.
      common="$WINEPREFIX/drive_c/Program Files (x86)/Steam/steamapps/common"
      mkdir -p "$common"
      ln -sfn ${lib.escapeShellArg "${payload}"} "$common/${gameFolder}"

      ${lib.optionalString (steamAppId != null) ''
        # Let a (non-enforcing) steam_api initialize offline without a steam_appid.txt file
        # (which we can't write beside the read-only exe). Not DRM circumvention.
        export SteamAppId=${toString steamAppId}
        export SteamGameId=${toString steamAppId}
      ''}
      ${forceDxmt}
      # Run from the game dir so relative asset paths resolve.
      cd "$common/${gameFolder}"
    '';
    launchCmd = ''"${wineBin}" ${lib.escapeShellArg "C:/Program Files (x86)/Steam/steamapps/common/${gameFolder}/${cfg.exe or "game.exe"}"}'';
  };

  # --- Branch 2: not captured yet — a launcher that explains how to capture ---
  guidance = {
    package = wineBundle;
    runtimeInputs = [ ];
    reconcile = "";
    launchCmd = "${pkgs.writeShellScript "hc-${gameName}-uncaptured" ''
        cat >&2 <<'EOF'
      hermetic-couch: ${gameName} has no captured payload yet.
      This is a Tier-B (your-own-copy) game, so capture it once:
        1) nix run .#hc-steam-provision            # boot Steam, log in, install "${gameName}"
        2) nix run .#hc-capture -- ${gameName}    # version=Steam buildid, appid+folder from this spec
        3) set play + paste the versions."<version>" stanza into games/${gameName}.nix,
           set runnerConfig.exe to the game's exe (relative to its folder), then re-run.
      If it turns out ${gameName} enforces Steam DRM at launch (encrypted exe / ownership
      check), set runnerConfig.launchViaSteam = true instead (non-hermetic fallback).
      EOF
        exit 1
    ''}";
  };

  # --- Branch 3: hybrid — captured store bytes, Steam runs only for the auth token ---
  # For steamStub games that render from static files but need a live Steam session. We do
  # NOT launch via `-applaunch`: that injects the Steam overlay into the game, which
  # deadlocks the wine loader. Instead we boot Steam in the BACKGROUND (auth provider only)
  # and launch the game exe DIRECTLY from the store payload — SteamAPI in the game
  # authenticates against the running, logged-in Steam via the shared prefix registry (the
  # standard steam_appid.txt dev workflow). Bytes stay content-addressed; no re-download.
  hybrid = {
    package = payload;
    inherit runtimeInputs;
    reconcile = ''
      ${envAndPrefix}
      ${steamInstall}

      # Expose the read-only store payload at the path the game expects (bytes stay in store).
      common="$WINEPREFIX/drive_c/Program Files (x86)/Steam/steamapps/common"
      mkdir -p "$common"
      ln -sfn ${lib.escapeShellArg "${payload}"} "$common/${gameFolder}"

      # Boot Steam in the background as the auth provider; wait (bounded) until it's logged
      # in. ActiveUser != 0 in the prefix registry means a live, signed-in session.
      _au() { "${wineBin}" reg query 'HKCU\Software\Valve\Steam\ActiveProcess' /v ActiveUser 2>/dev/null | tr -d '\r' | grep -oiE '0x[0-9a-f]+' | tail -1; }
      cur="$(_au || true)"
      if [ -z "$cur" ] || [ "$cur" = "0x0" ]; then
        echo "hermetic-couch: booting Steam (auth provider); log in if prompted…" >&2
        "${wineBin}" ${lib.escapeShellArg steamExe} -silent -no-browser >/dev/null 2>&1 &
        for _ in $(seq 1 90); do cur="$(_au || true)"; { [ -n "$cur" ] && [ "$cur" != "0x0" ]; } && break; sleep 2; done
      fi
      { [ -n "$cur" ] && [ "$cur" != "0x0" ]; } || \
        echo "hermetic-couch: WARNING — Steam not logged in yet; use the game's Retry Login once it is." >&2

      export SteamAppId=${toString steamAppId}
      export SteamGameId=${toString steamAppId}
      ${forceDxmt}
      cd "$common/${gameFolder}"
    '';
    launchCmd = ''"${wineBin}" ${lib.escapeShellArg "C:/Program Files (x86)/Steam/steamapps/common/${gameFolder}/${cfg.exe or "game.exe"}"}'';
  };

  # --- Branch 4: explicit non-hermetic fallback — Steam installs AND runs the game ---
  viaSteam = {
    package = wineBundle;
    inherit runtimeInputs;
    reconcile = ''
      ${envAndPrefix}
      ${steamInstall}
      ${forceDxmt}
    '';
    launchCmd =
      if steamAppId != null then
        ''"${wineBin}" ${lib.escapeShellArg steamExe} -applaunch ${toString steamAppId}''
      else
        ''"${wineBin}" ${lib.escapeShellArg steamExe}'';
  };
in
if launchViaSteam then
  viaSteam
else if captured && needsSteamAuth && steamAppId != null then
  hybrid
else if captured then
  hermetic
else
  guidance
