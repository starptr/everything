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

## Part 2 — wine runner + Meccha Chameleon  (deferred)
- [ ] runners/wine.nix: fetch frankea-Whisky prebuilt wine+D3DMetal (jujutsu-bin pattern)
- [ ] inject pinned DXMT DLLs + DLL overrides
- [ ] winetricks verbs applied idempotently (state-file tracked)
- [ ] prefix reconciler (wineboot if absent; install Steam)
- [ ] preLaunch: boot Steam, wait for login/ownership (drm=steamStub)
- [ ] games/maccha-chameleon.nix
- [ ] verify: prefix provisions, Steam login, game renders via DXMT/Metal

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
- [ ] bin/hc-capture (Pattern B): tar steamapps/common/<game> → add to store → read
      .acf buildid → print the `versions."<v>" = { … }` stanza for the user's config
- [ ] bin/hc-check (Pattern B): live buildid vs pinned; drift warning
- [ ] wire both into versions.nix (shared committed lockfile vs user-supplied versions attr)

## Part 5 — integration  (deferred)
- [ ] add mac-app-util input; register .app into ~/Applications (Spotlight/Dock)
- [ ] path flake input into flake-profiles/system-sodium + nixpkgs overlay
- [ ] enable games.<name> in venus/modules/home-manager/sodium.nix
- [x] fully-pinned/offline Minecraft — DONE in Part 1 via the payload FOD + offline portablemc.
      (Remaining nicety: drop portablemc at runtime entirely by hand-assembling the java command — not needed.)
- [ ] Rosetta at system tier (softwareupdate --install-rosetta) for Part 2
