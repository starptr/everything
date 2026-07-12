# hermetic-couch — implementation TODO

Design: ./DESIGN.md. Legend: [ ] pending · [~] in progress · [x] done.

## Part 0 — core framework  (this milestone) — DONE
- [x] flake.nix (nixpkgs-unstable + flake-utils, aarch64-darwin, flat packages/apps, HM module output)
- [x] lib/mkGame.nix (compose runner → launcher (writeShellScriptBin) + app)
- [x] lib/mkAppBundle.nix (store <Name>.app: Info.plist + MacOS stub + Resources; bin symlink)
- [x] lib/reconcile.nix (seedIfAbsent / writeManaged / ensureDir helpers)
- [x] lib/versions.nix (versions/play/compat assertions; used from Part 2/4)
- [x] module.nix (games = attrsOf submodule; home.packages launchers+apps)
- [x] runners/native.nix
- [x] runners/love2d.nix (reuses local pkgs/love.nix, = soup's love derivation)
- [x] games/love-hello (trivial in-repo love2d game; offline pipeline proof)
- [x] verify (structural): `nix flake check` green; `love --version` runs; Info.plist `plutil -lint` OK
- [ ] verify (interactive, user): `nix run .#love-hello` → window opens; `open` the store .app

## Part 1 — Minecraft + Sodium (java runner) — HERMETIC  (this milestone) — DONE (pending in-game re-check)
- [x] lib/fetch-mod.nix (Modrinth CDN fetchurl; Sodium jar sha256 via nix-prefetch-url, verified real jar)
- [x] pkgs/minecraft-payload.nix (HERMETIC payload FOD: client+libraries+natives+assets+Fabric as ONE
      content-addressed store path; built via `portablemc start --dry`; determinism verified via `nix build --rebuild`)
- [x] runners/java.nix (DIRECT offline launch — read-only store `--main-dir` + `--fetch-exclude-all`;
      pinned JRE via `--jvm`; stage/relink mods; seed options.txt; one-time `portablemc auth login` cached in instance dir)
- [x] games/minecraft-sodium.nix (MC 1.21.1 + Fabric 0.16.10 + Sodium 0.6.0; payloadHash pinned)
- [x] decisions: dropped Prism (made its onboarding imperative); then made it fully hermetic
      (only the MS OAuth token is runtime — an irreducible per-user secret)
- [x] verify (structural): flake check green; offline launch from read-only payload confirmed (no network, no store writes)
- [ ] verify (interactive, user): `nix run .#minecraft-sodium` → game launches offline from the pinned payload,
      Sodium active in Video Settings/F3; version bump swaps jar

Notes:
- Files are `git add`-staged (required for flake evaluation) but NOT committed.
- Not wired into system-sodium/sodium.nix yet (standalone, per plan) — that's Part 5.

## Part 2 — wine runner + MECCHA CHAMELEON  (this milestone) — SCAFFOLD DONE (pending on-device verify)
Steam title is **MECCHA CHAMELEON**, App ID **4704690** (Windows-only, $5.99). DESIGN
still spells it "maccha" in a couple of places; the code uses the correct "meccha".
- [x] pkgs/whisky-wine.nix (relocate frankea/Whisky `Libraries.tar.gz` v3.1.1 into the store;
      dontFixup keeps signatures; VERIFIED runs from store — `wine-11.0`, arm64, no external dylibs)
- [x] DXMT: the Whisky bundle ships DXMT dlls (`DXMT/{x64,x32}`, 5.3MB real Metal d3d11) +
      `winemetal.so` builtin, but a fresh prefix's d3d11 is wine's own wined3d (fakedll stub) which
      canNOT give Unreal a Feature-Level-11 device (the "D3D11-compatible GPU required" popup).
      FIX: runner INJECTS the bundle's DXMT dlls into the prefix system32/syswow64 and forces them
      native (`WINEDLLOVERRIDES=d3d11,dxgi,d3d10core=n,b`). (Earlier "builtin, no injection" was a
      misread — wine builtin d3d11 = wined3d, not DXMT; DXMT is the NATIVE dll.)
- [x] pkgs/winetricks-min.nix (GUI-less winetricks from the upstream script; nixpkgs winetricks
      drags in zenity→GTK/libadwaita/appstream which FAILS to build on darwin)
- [x] REWORKED to a hermetic capture→store→offline-launch model (mirrors the java runner);
      Steam is a capture-time tool, NOT a launch dependency. FOUR runner branches:
      captured (DRM-free)→hermetic offline launch · captured+drm=steamStub→HYBRID (store bytes +
      Steam booted in-prefix only for the auth token) · uncaptured→prints capture steps ·
      `launchViaSteam=true`→non-hermetic fallback (Steam installs AND runs the game).
- [x] ON-DEVICE FINDING: MECCHA is an Unreal Engine game. After the DXMT-native fix it RENDERS
      hermetically from the store payload (title screen) — proving graphics + hermetic bytes work.
      But it then gates on a live Steam auth token ("Failed due to invalid/missing auth token") →
      it's a row-2 DRM (steamStub) title. So drm="steamStub" now selects the HYBRID branch. First cut
      used Steam `-applaunch`, but that injects the Steam overlay into the game and DEADLOCKED the wine
      loader (`RtlpWaitForCriticalSection … loader_section … timed out`). FIX (v2): boot Steam in the
      BACKGROUND purely as the auth provider (poll ActiveUser reg for logged-in), then launch the game
      exe DIRECTLY from the store payload (no -applaunch → no overlay injection). SteamAPI in the game
      authenticates against the running Steam via the shared-prefix registry (steam_appid.txt dev
      workflow) with SteamAppId env set. Bytes stay content-addressed; login persists in the prefix.
- [x] pkgs/steam-game-payload.nix (requireFile the game DIRECTORY directly, recursive/content-
      addressed — no tar, no unpack, one store copy; marked unfree, never cached — DESIGN §1)
- [x] pkgs/tools/hc-steam-provision.nix (boot Steam in a scratch prefix in the pinned env; impure)
- [x] pkgs/tools/hc-capture.nix (content-address steamapps/common/<game> dir via
      `nix-store --add-fixed --recursive` → read .acf buildid → print the per-user
      `versions."<v>"` stanza). Exposed as flake apps.
      GAME-AWARE + minimal args: appid + steam-folder are baked from each wine spec into a
      slug→{appId;folder} table, and version defaults to the Steam buildid (read from .acf).
      So `hc-capture -- <slug>` is enough; [version] [appid] [folder] are positional overrides.
- [x] runners/wine.nix hermetic branch: minimal prefix reconcile (wineboot mono/gecko-suppressed
      + idempotent winetricks) → symlink read-only store payload into the prefix → force builtin
      DXMT + set SteamAppId (offline steam_api init, NOT DRM circumvention) → exec exe, no Steam.
- [x] lib/wine-pin.nix (single source of truth for the Whisky bundle pin; runner + tools share it)
- [x] games/meccha-chameleon.nix ships UNCAPTURED (versions={}, play=null); gameFolder/exe are
      best-guesses to confirm on first capture. drm=steamStub, vcrun2022, appId 4704690.
- [x] module.nix: added `play`, `versions`, `gameName` options (+ earlier `drm`, `wine` runner)
- [x] verify (structural): `nix flake check` green; tools build (writeShellApplication shellcheck
      passes); uncaptured launcher builds + prints correct guidance; .app + Info.plist OK
- [ ] verify (interactive, user — needs Rosetta 2 + your owned copy):
      1) `nix run .#hc-steam-provision` → log in, install MECCHA CHAMELEON, quit Steam
      2) `nix run .#hc-capture -- meccha-chameleon` (version=buildid, appid/folder from spec) → stanza
      3) set play = "24149874" + paste versions."24149874" into games/meccha-chameleon.nix
         (gameFolder="MECCHA CHAMELEON", exe="PenguinHotel.exe" — all confirmed from the real install)
      4) `NIXPKGS_ALLOW_UNFREE=1 nix run .#meccha-chameleon` → launches from store, no Steam, DXMT/Metal.
         If it refuses without Steam → it's a row-2 DRM title → set launchViaSteam=true.
      Rosetta 2 is system-tier (Part 5); runner warns if absent (`softwareupdate --install-rosetta`).

Notes:
- Impurity is confined to provision/capture (winetricks MS-redists + Steam bootstrap, into the
  scratch provisioning prefix). The hermetic LAUNCH is offline; only the mutable save/config
  prefix + the one-time winetricks redist (into `$INSTANCE_DIR/cache`) are written at launch.
- CONTAINMENT: `WINEPREFIX` + `XDG_CACHE_HOME` both under `$INSTANCE_DIR`; winetricks-min uses curl
  (no `~/.wget-hsts`). The ONE irreducible out-of-dir artifact is
  `~/Library/Preferences/org.winehq.wine.plist` (42 B, macOS CFPreferences, shared w/ system Whisky).
- hc-check (buildid drift warning) still TODO (Part 4); provision + capture are now built here.
- Per-user payloads are unfree → build with `NIXPKGS_ALLOW_UNFREE=1`; never push to Cachix.

## Part 3 — emulator runner  (deferred)
- [ ] runners/emulator.nix (retroarch + cores); requireFile ROMs

## Part 4 — capture / version tooling  (deferred)
Two distinct pinning patterns, split by whether the artifact bytes are the same for
every hermetic-couch user. Both are nix-BUILT commands but RUN impurely (network),
and both feed the same versions/play/compat machinery (lib/versions.nix).

### Pattern A — shared hashes (public / redistributable)
Bytes are byte-identical for everyone (public URL: Mojang/Fabric, Modrinth, GitHub
releases, freeware). Mapping is COMMITTED to the hermetic-couch repo as a shared
lockfile (like flake.lock) and reused by all users. Credentials-free; network only.
Minecraft payload + Sodium are this kind. This is the Minecraft version-bump SOP.
- [ ] bin/hc-lock (Pattern A): for a target version, resolve payload/mod/source hashes
      (payload FOD hash + Modrinth/URL prefetch) → write committed games/<game>.lock.json
- [ ] games read `builtins.fromJSON (readFile ./<game>.lock.json)`, select by `play`
- [ ] enforce DESIGN §4 compat (min/max/known) at lock time

### Pattern B — per-user hashes (private / non-redistributable / locally-captured)
Bytes come from the user's OWN copy (Steam steamapps/common/<game>, purchased
installer). NOT committable (licensing + world-readable store) and maybe machine-
specific (CEG). Mapping is NOT in the repo — the user supplies it via a parameter in
THEIR OWN config (`games.<game>.versions."<v>" = { hash; buildid; }`). A non-hermetic
local script both (a) ingests that version's copy into the user's nix store
(requireFile / `nix-store --add-fixed`) and (b) prints the version→hash stanza to
paste. Meccha is this kind.
- [x] hc-capture (Pattern B): content-address steamapps/common/<game> dir → add to store →
      read .acf buildid → print the `versions."<v>" = { … }` stanza (DONE in Part 2)
- [ ] bin/hc-check (Pattern B): live buildid vs pinned; drift warning
- [ ] wire both into versions.nix (shared committed lockfile vs user-supplied versions attr)

## Part 5 — integration  (deferred)
- [ ] add mac-app-util input; register .app into ~/Applications (Spotlight/Dock)
- [ ] path flake input into flake-profiles/system-sodium + nixpkgs overlay
- [ ] enable games.<name> in venus/modules/home-manager/sodium.nix
- [x] fully-pinned/offline Minecraft — DONE in Part 1 via the payload FOD + offline portablemc.
      (Remaining nicety: drop portablemc at runtime entirely by hand-assembling the java command — not needed.)
- [ ] Rosetta at system tier (softwareupdate --install-rosetta) for Part 2
