# hermetic-couch — declarative games on nix-darwin

A generic, declarative framework for fetching arbitrary games into the Nix
store and scaffolding them to run with a chosen configuration on macOS
(Apple Silicon), managed as home-manager modules.

> Status: design / pre-implementation. This doc is the source of truth for the
> phase-1 build.

## Goals

- One declarative interface — `games.<name>` — for wildly heterogeneous games:
  source builds, engine games (Love2D/Godot/Java), emulated games, and
  Windows/Steam games run through a Wine compatibility stack.
- Two problems, solved generically:
  1. **Fetch** game bits into the Nix store (hash-pinned, cacheable).
  2. **Scaffold** the game to run with the config we want on darwin.
- Version is first-class, declared, and validated state.
- Games surface as both real `.app` bundles (Spotlight/Dock/Launchpad) *and*
  `nix run .#games.<name>`.

## Non-goals

- Bypassing DRM, or redistributing commercial games. Commercial bits stay
  local-only (`unfree`, never pushed to a shared/public cache).
- Rebuilding Wine from source on darwin (flaky; we fetch prebuilt instead).
- Cross-platform. This targets nix-darwin / Apple Silicon.

---

## 1. Core model: two purity tiers, classified by DRM

Not everything can be pure. The framework splits games into two tiers, and the
tier is a property of the game's **DRM behavior at launch**, *not* of where the
game came from.

- **Tier A — fully declarative (in-store).** Redistributable or DRM-free bits.
  The whole game lives in the store, hash-pinned and Cachix-cacheable. Only
  saves/settings are mutable. Reproducible.
- **Tier B — hybrid.** DRM/Steam/Wine games. The *environment* (runner,
  translation layers, launch args, mods, prefix config) is declarative and
  hash-pinned; the *content* (a Steam-installed game, a Wine prefix, saves) is
  mutable and reconciled onto a mutable instance directory at launch.

### The DRM axis (for manually-captured games)

You *can* add a Steam game's `steamapps/common/<game>` directory into the store
via `requireFile` (recursive, content-addressed). Whether the result runs
standalone depends on DRM:

| DRM behavior | Files → store? | Runs from the copy? | Tier |
|---|---|---|---|
| DRM-free once installed | yes | yes, standalone | **A** |
| Steam-stub (`steam_api*.dll` + Steam running + ownership) | yes | only with Steam booted & authed in the prefix | **B** |
| CEG / machine-bound / Denuvo | copy works | fragile / machine-locked | not portable |

Two non-DRM constraints on captured games:

1. **Manual capture, not fetch.** There is no URL+hash — you snapshot the
   installed dir with `requireFile` and re-capture on each update. This is a
   feature (deliberate version pinning), but it is a manual step.
2. **Cache & permissions.** `/nix/store` is world-readable and we push to
   Cachix. Commercial bits must be marked `unfree` and **never** pushed to a
   shared cache. Build locally; keep local-only (or a private cache).

---

## 2. Architecture

### 2.1 Repo layout

```
experimental/hermetic-couch/
  flake.nix                 # exposes the HM module + packages.games.* + apps.games.*
  module.nix                # the games.<name> home-manager module (core schema)
  lib/
    mkGame.nix              # core: spec → { package, reconcile, launcher, app }
    mkAppBundle.nix         # Foo.app generator (Info.plist + wrapper + icns)
    reconcile.nix           # instance-dir seeding helper (shared by all runners)
    versions.nix            # version/compat validation (lib.versions)
  runners/
    native.nix              # Tier A prebuilt binaries
    love2d.nix  godot.nix   # Tier A engines
    java.nix                # Minecraft + mods (packwiz)
    emulator.nix            # RetroArch + cores + ROMs
    wine.nix                # Wine stack: Maccha etc.
  games/                    # one file per game — pure data + per-game automation
    celeste-classic.nix  minecraft-atm.nix  maccha-chameleon.nix
  bin/
    hc-capture              # snapshot a Steam/Wine game dir → requireFile stanza
    hc-check                # diff pinned buildid vs live Steam buildid (drift)
```

### 2.2 The runner-adapter contract

The core stays tiny; each game class is one adapter. A runner is a function
returning exactly three things:

```nix
# runners/<kind>.nix : { source, settings, mods, version, lib, pkgs } -> {
  package   = <drv>;         # immutable bits in the store
  reconcile = ''<bash>'';    # idempotent: seed/update instanceDir before launch
  launchCmd = "…/bin/…";     # the exec line
}
```

`lib/mkGame.nix` composes those into **both** launch surfaces from one source
of truth:

- `launcher` — a `makeBinaryWrapper` script: run `reconcile`, apply
  `launch.env` / `preLaunch`, then `exec launchCmd`. Backs `apps.games.<name>`.
- `app` — `mkAppBundle` wrapping that same launcher, materialized into
  `~/Applications` via **mac-app-util** so Spotlight/Dock/Launchpad index it.

So "both launch surfaces" costs nothing per game — generated once in the core.

### 2.3 The module schema

```nix
games.<name> = {
  enable  = true;
  runner  = "native" | "love2d" | "godot" | "java" | "emulator" | "wine" | "custom";

  # ─ Fetch (Problem 1) ─ exactly one source strategy; see §3
  source  = { … };

  # ─ Versioning ─ see §4
  versions = { "<ver>" = { … }; };   # for requireFile/manual sources
  play     = "<ver>";                # REQUIRED — which version runs

  # ─ Config (Problem 2) ─ rendered via pkgs.formats
  settings = { … };

  # ─ Optional ─
  mods    = [ … ];                   # runner-dependent (java/emulator/wine)
  drm     = "none" | "steamStub" | "machineBound";

  # ─ Run ─
  instanceDir = "~/Library/Application Support/hermetic-couch/<name>";
  launch  = { args = []; env = {}; preLaunch = ""; };
  app     = { enable = true; name = "<Name>"; icon = ./icon.icns; };
};
```

---

## 3. Problem 1 — fetching into the store

A small menu of fetch strategies, one per game:

| Game shape | Strategy |
|---|---|
| GitHub source / release | `fetchFromGitHub` / `fetchzip` + hash |
| Freeware binary, public URL | `fetchurl` / `undmg` / `_7zz` unpack |
| Paid / itch / GOG (redistributable to you) | `requireFile` — download once, pin by hash |
| Steam / DRM | **manual capture** → `requireFile` on a tarball of the install (Tier B; see §1) |
| Mods (Minecraft etc.) | lockfile-driven FODs via **packwiz** (`packwiz2nix`) |

Honest boundary: **Steam/DRM games are not fetchable via URL+hash.** They are
manually captured snapshots (§4), and their bits are `unfree`/local-only.

---

## 4. Versioning — mandatory, declared, validated

There is no upstream URL to derive a version from for a hand-captured tarball,
so the framework refuses unlabeled snapshots and refuses to run a selection it
can't prove is supported.

### Two pinning patterns (shared vs per-user hashes)

Version→hash pins fall into two kinds, by whether the artifact bytes are identical
for every hermetic-couch user:

- **Shared hashes — public / redistributable.** Bytes come from a public URL
  (Mojang/Fabric, Modrinth, GitHub releases, freeware) and are byte-identical for
  everyone. The version→hash mapping is **committed to the hermetic-couch repo** (a
  shared lockfile, like `flake.lock`) and reused by all users; the capture step is a
  credentials-free network fetch. Minecraft's payload + the Sodium mod are this kind.
- **Per-user hashes — private / non-redistributable / locally-captured.** Bytes come
  from the user's *own* copy (Steam `steamapps/common/<game>`, a purchased installer)
  and are neither committable (licensing + the world-readable store) nor necessarily
  identical across machines (CEG). The user supplies the mapping via a parameter in
  **their own** config (`versions."<v>" = { … }`), obtained by running a non-hermetic
  local script that both ingests that copy into their nix store (requireFile /
  `nix-store --add-fixed`) and prints the stanza to paste. Meccha is this kind.

Both feed the same `versions`/`play`/`compat` machinery below; they differ only in
*where the mapping lives* (committed shared lockfile vs per-user config) and *how it's
produced* (network fetch vs local capture). See §11 Part 4 for the two capture tools.

### 4.1 Two facts + one constraint

- **Captured version(s)** — every `requireFile` snapshot *must* carry a version
  label. No mystery tarballs. Multiple captures may coexist.
- **Selected version (`play`)** — REQUIRED; no defaulting to "latest".
- **Compatibility contract** — declared by the per-game file, validated at
  **eval time** (`assert`), so a bad pin fails `nix build`, not at runtime.

```nix
games.maccha-chameleon = {
  runner = "wine";
  drm    = "steamStub";
  versions = {
    "1.2.0" = { requireFile = { name = "maccha-1.2.0.tar.zst"; sha256 = "…"; }; buildid = 12648101; };
    "1.3.1" = { requireFile = { name = "maccha-1.3.1.tar.zst"; sha256 = "…"; }; buildid = 13277540; };
  };
  play = "1.3.1";   # REQUIRED
};
```

### 4.2 The compat contract (min / max / known-set)

Declared per game; enforced by the core with `lib.versions` (no custom compare):

```nix
# games/maccha-chameleon.nix
compat = { min = "1.2.0"; max = null; known = [ "1.2.0" "1.3.1" ]; };

# lib/versions.nix — eval-time assertions
assertions = [
  { assertion = cfg.versions ? ${cfg.play};
    message = "maccha: no captured snapshot for ${cfg.play}; run `hc-capture --version ${cfg.play}`"; }
  { assertion = lib.versionAtLeast cfg.play compat.min;
    message = "maccha: ${cfg.play} < minimum supported ${compat.min}"; }
  { assertion = compat.max == null || !(lib.versionOlder compat.max cfg.play);
    message = "maccha: ${cfg.play} exceeds tested max ${compat.max}"; }
  { assertion = lib.elem cfg.play compat.known;
    message = "maccha: ${cfg.play} not in known-good set ${toString compat.known}"; }
];
```

A mismatch is a legible build failure, not a crash three layers into Wine.

### 4.3 Two version identifiers

- **human version** (`1.3.1`) — drives `min`/`max`/`known`; semver-orderable.
- **Steam `buildid`** (monotonic, authoritative) — identity cross-check + drift
  detection, auto-read from `appmanifest_<appid>.acf`.

For a Steam game these coincide by default: `hc-capture` uses the buildid as the
`play` version unless you pass a human label — so `versions."24149874"` is the
zero-typing default, and a semver label is opt-in.

### 4.4 Helpers

- `hc-capture <slug> [version]` — tars `steamapps/common/<game>`, hashes it into
  the store, auto-reads `buildid` from the `.acf`, and prints the ready-to-paste
  `versions.<v>` stanza. Slug alone suffices: appid + folder come from the game
  spec, and the version defaults to the buildid.
- `hc-check` — reads the live `.acf` buildid and warns when Steam has moved past
  the pinned snapshot ("pinned 1.3.1 / buildid 13277540, Steam now 134…").
  This is the "current version of the game" signal, active rather than static.

### 4.5 Version-parameterized automation

The selected version can *drive* the adapter, not just gate it:

```nix
launchArgs = v: lib.optional (lib.versionAtLeast v "1.3.0") "--metal-hud";
winetricks = v: [ "vcrun2022" ] ++ lib.optional (lib.versionOlder v "1.3.0") "d3dcompiler_47";
```

Switching `play` re-derives the correct environment deterministically.

---

## 5. Problem 2 — scaffolding & running

### 5.1 Settings-as-code

`settings = { … }` is rendered with `pkgs.formats.{ini,toml,json,keyValue}`
into a store file. `reconcile` seeds it into the mutable instance dir
(managed section only, so hand-edits survive). Same mechanism whether the
target is `options.txt`, a Love2D `conf`, or a Wine registry key.

### 5.2 State reconciliation (the crux)

Games need to write; the store is read-only. So the launcher reconciles the
immutable spec onto the mutable `instanceDir` on **every launch**:

- symlink store content in,
- seed default config if absent,
- apply managed overrides,
- then `cd` + `exec`.

For Tier A this is a few `ln -sfn` + a first-run `cp`. For Wine the instance
dir *is* the prefix, and reconcile becomes a tiny declarative prefix manager:
create if missing (`wineboot`), apply un-applied winetricks verbs idempotently
(track applied verbs in a state file), install graphics DLLs, set registry
keys. This is the one genuinely novel component.

### 5.3 Launch surfaces

Both generated from the single `launcher` (§2.2): a `.app` bundle (via
mac-app-util) and a flake app (`nix run .#games.<name>`).

---

## 6. The `wine` runner in depth

The Windows-game stack is **layered and separable** — pick one option per
layer. Whisky-the-app is *not* a layer we depend on.

| Layer | Job | Options (Maccha in **bold**) | Nix approach |
|---|---|---|---|
| CPU x86→ARM | run x86_64 wine+game on ARM | **Rosetta 2** | system-level: `softwareupdate --install-rosetta` |
| Win32 API | Windows APIs | **frankea-Whisky prebuilt wine** / Apple GPTK / stock `pkgs.wine` | **fetch prebuilt**, don't build (darwin wine is flaky) |
| DirectX→Metal | translate D3D → Metal | **DXMT** / D3DMetal / DXVK+MoltenVK | the Whisky bundle **ships DXMT dlls** (`DXMT/{x64,x32}`) + `winemetal.so` builtin; the runner injects them into the prefix as **native** (wine's own builtin d3d11 is wined3d) — one pinned artifact covers this layer too |
| Prefix provisioning | VC++ redists, DLL overrides | **winetricks** | in nixpkgs; runtime redist fetch is the one impure spot |
| Distribution / DRM | deliver the game | **Steam** (login+install, or capture) | Tier B / `requireFile` (§1) |

### Whisky's actual role

The original `whisky-app/whisky` was **archived April 2025**; **frankea/Whisky**
is the active fork (the default Homebrew cask still installs the dead original —
you'd need the `frankea/whisky/whisky` tap). Whisky is a SwiftUI GUI
bottle-manager; everything it does at runtime is *exactly what our `reconcile` +
`wine` runner replaces*. We take **no runtime dependency** on Whisky.app — we
fetch its **prebuilt, signed wine + D3DMetal bundle as a pinned artifact** and
orchestrate it ourselves.

DXMT (3Shain) is now the best-performing D3D11→Metal path on Apple Silicon
(ahead of DXVK+MoltenVK and D3DMetal), which is why Maccha swaps it in.

### Runner config

```nix
games.meccha-chameleon.runnerConfig = {
  wine       = { source = "frankea-whisky"; version; url; hash; };  # pinned Libraries.tar.gz
  graphics   = "dxmt";                          # inject the bundle's DXMT dlls into the prefix, forced native
  winetricks = v: [ "vcrun2022" ] ++ lib.optional (lib.versionOlder v "1.3.0") "d3dcompiler_47";
  steam.appId = 4704690;                        # drm = "steamStub" → launch boots Steam + -applaunch
};
```

winetricks is the one impurity (it downloads MS redists at runtime). Tolerable
because the prefix is mutable Tier-B state anyway; for purity, pre-fetch the
redists as FODs and seed `~/.cache/winetricks` in `reconcile`.

Refs: [frankea/Whisky](https://github.com/frankea/Whisky) ·
[Whisky archived](https://appleinsider.com/articles/25/04/16/whisky-development-ends-on-macos-to-help-wine-flourish) ·
[3Shain/DXMT](https://github.com/3Shain/dxmt) ·
[GPTK](https://www.applegamingwiki.com/wiki/Game_Porting_Toolkit)

---

## 7. Darwin-specific gotchas

- **Symlinked `.app`s don't index** in Finder/Spotlight/Dock. Use
  **mac-app-util** (hraban/mac-app-util) — trampoline copies. Built for exactly
  this.
- **Quarantine is in our favor.** Nix fetchers don't set `com.apple.quarantine`,
  so store apps sidestep the "unidentified developer" Gatekeeper wall.
- **Don't modify signed binaries** (breaks the signature). If unavoidable,
  ad-hoc re-sign: `codesign -s - …`.
- **System vs user split.** Rosetta + Homebrew casks (if ever needed) →
  nix-darwin (`homebrew.casks`, note the frankea tap). Per-game config + saves →
  home-manager.
- **Secrets** (game accounts, keys) → existing sops-nix.

---

## 8. Worked examples

- **Love2D indie game (Tier A, easy).** `source = fetchFromGitHub`,
  `runner = "love2d"`, `settings` → store, reconcile seeds save dir, `.app`
  generated. Fully reproducible + Cachix-cached. First target.
- **Minecraft + mods (Tier A, medium).** JRE + Fabric loader + `mods` via a
  packwiz lockfile, all `symlinkJoin`'d into an immutable skeleton; only
  `saves/` + `options.txt` mutable. Prior art: nix-minecraft, packwiz2nix.
- **Maccha Chameleon (Tier B, hard).** `runner = "wine"`, `drm = "steamStub"`.
  Declarative: pinned frankea-Whisky wine + DXMT + winetricks verbs + launch
  flags + `.app`. Mutable: the prefix (Steam auth + install). Replaces the
  upstream 200-line `install.command` with a versioned, reproducible-environment
  spec.

---

## 9. Validation targets

The framework is validated against **two concrete builds**, chosen to exercise
the two hardest runners end-to-end: `java` (mods) and `wine` (Windows/Steam on
macOS). They are the acceptance criteria for "this works." (Note: this
front-loads roadmap phases 3–4 — see §11. A trivial `native`/`love2d` game is
still the fastest way to prove the phase-1 core first.)

### 9.1 Minecraft + Sodium — `java` runner, Tier A skeleton

Goal: prove the `java` runner — loader, mod fetch, immutable skeleton / mutable
saves, and both launch surfaces. A deliberately *simple* distribution: one mod.

Sodium (CaffeineMC) is a client-side Fabric rendering optimizer distributed on
Modrinth. As of 0.6.0+ it bundles the Fabric Rendering API, so it needs **no
Fabric API and no Indium** — the mod list is just Sodium. (Not to be confused
with the `sodium` *machine* in this repo.)

```nix
games.minecraft-sodium = {
  runner = "java";
  play   = "1.21.1";                       # Minecraft version
  runnerConfig = {
    minecraft = "1.21.1";
    loader = { kind = "fabric"; version = "0.16.x"; };
    jre    = pkgs.temurin-bin-21;           # MC 1.21 requires Java 21
  };
  mods = [
    (fetchMod {                             # Sodium from Modrinth; single mod, no Fabric API
      slug = "sodium"; version = "mc1.21.1-0.6.0-fabric";
      url = "https://cdn.modrinth.com/data/AANobbMI/versions/…/sodium-….jar";
      sha256 = "…";
    })
  ];
  settings = { renderDistance = 12; fullscreen = false; };  # → options.txt, managed keys only
};
```

Dependencies pinned: the entire game payload (client jar, all vanilla libraries +
natives, the full asset set, and the Fabric loader) as a single content-addressed
store path, plus the JRE, the Sodium jar (Modrinth FOD), and portablemc.

**Direct launch, no GUI launcher.** hermetic-couch launches Minecraft itself
rather than delegating to a launcher/config-manager (an earlier Prism-backed
sketch was rejected: it made Prism's own onboarding imperative). The `java`
runner uses **portablemc** as a headless resolver/executor: at *build* time
`pkgs/minecraft-payload.nix` runs `portablemc start --dry` inside a fixed-output
derivation to fetch + resolve the whole payload, keeping only the deterministic
`versions/libraries/assets` trees (verified reproducible via `nix build
--rebuild`). At *launch* time the runner runs `portablemc start` with a
**read-only store `--main-dir` (the payload) and `--fetch-exclude-all`**, so it
execs the `java` Minecraft process entirely offline — no network, no writes to the
store. Only mutable game state (`--mc-dir`/`--bin-dir`: saves, mods, options,
logs, natives, auth cache) lives in the instance dir.

**The one irreducible boundary.** Everything except **Microsoft-account auth** is
pinned in the store and offline-reproducible. The auth token is a per-user,
expiring OAuth secret: one-time `portablemc auth login`, cached in the mutable
instance dir (`portablemc_msa.json`), **never** in the world-readable store — the
same secret tier as Steam login for a Wine game, and inherent to online Minecraft
(no launcher can make it declarative).

Acceptance criteria:

- `nix run .#games.minecraft-sodium` launches a modded client; Sodium shows in
  Video Settings and the F3 renderer line.
- A `.app` ("Minecraft (Sodium)") appears in Spotlight/Launchpad and launches.
- Saves + `options.txt` persist across relaunch.
- Bumping the pinned Sodium version and rebuilding swaps the jar
  deterministically.

### 9.2 Meccha Chameleon — `wine` runner, Tier B

Goal: prove the full `wine` stack — the layered dependency set, the declarative
prefix reconciler, and the `steamStub` launch flow. This replaces upstream's
~200-line `install.command` with a versioned, reproducible-*environment* spec;
the game bits install into the mutable prefix via Steam (Tier B), and everything
around them is pinned.

The "required dependencies to run on macOS", packaged:

- **Rosetta 2** — system-level (nix-darwin activation:
  `softwareupdate --install-rosetta --agree-to-license`).
- **Wine** — frankea-Whisky prebuilt wine bundle (`Libraries.tar.gz`), relocated
  into the store + hash-pinned (no source build). Verified: it runs from the
  store (`wine-11.0`, arm64, no external dylib deps, signatures intact).
- **DXMT** — D3D11→Metal. The Whisky bundle ships the DXMT dlls (`DXMT/{x64,x32}`)
  and the `winemetal.so` builtin, but a fresh prefix's d3d11 is wine's own **wined3d**
  (D3D→Vulkan→MoltenVK), which can't give Unreal a Feature-Level-11 device. So the
  runner **injects DXMT's native dlls into the prefix** (`system32`/`syswow64`) and
  forces them native via `WINEDLLOVERRIDES=d3d11,dxgi,d3d10core=n,b`, beating wined3d.
  DXMT is version-matched to the wine build because it comes from the same pinned
  bundle — so one pinned artifact still covers both the Win32 and D3D→Metal layers.
- **winetricks** — `vcrun2022` (Visual C++ runtime), applied idempotently. Built
  GUI-less from the upstream script (pkgs/winetricks-min.nix) to avoid nixpkgs'
  zenity→GTK dependency chain, which fails to build on darwin.
- **Steam** — installed into the prefix; delivers + authenticates the game.

```nix
games.meccha-chameleon = {                    # Steam title: MECCHA CHAMELEON (App 4704690)
  runner = "wine";
  drm    = "steamStub";                 # needs Steam running + ownership; verify if actually DRM-free
  runnerConfig = {
    wine       = { source = "frankea-whisky"; version = "3.1.1"; url; hash; };  # pinned Libraries.tar.gz
    graphics   = "dxmt";                # Whisky's builtin DXMT (ABI-matched), forced builtin
    winetricks = [ "vcrun2022" ];       # list, or a fn of the play version
    steamAppId = 4704690;               # capture/provision + drift; sets SteamAppId at launch
    gameFolder = "MECCHA CHAMELEON"; exe = "…";   # confirmed on first capture
  };
  play = "…"; versions."…" = { sha256 = "…"; buildid = "…"; };  # ← from hc-capture (per-user)
};
```

**Launch is capture→store→offline, mirroring the java runner** — Steam is a
capture-time tool, NOT a launch dependency (an earlier Steam-at-launch sketch was
the non-hermetic shortcut and is now demoted to a fallback):

1. `hc-steam-provision` (non-hermetic, one-time) — boot Steam in a *scratch* prefix
   built from the pinned env; log in + install. Bits land in a runtime dir, never
   the store.
2. `hc-capture <name> [ver]` (non-hermetic, per-user) — content-address the
   `steamapps/common/<game>` directory → `nix-store --add-fixed --recursive` → print
   the `versions."<ver>"` stanza (unfree, never cached). `requireFile` (recursive)
   resolves it. Game-aware: the Steam appid + install folder are looked up from the
   game spec by slug (a build-time table), and the version defaults to the buildid, so
   just the slug is typed (positional `[ver] [appid] [folder]` override for ad-hoc).
3. hermetic launch — reconcile a minimal prefix (wineboot + winetricks verbs),
   inject the bundle's DXMT dlls native into the prefix, symlink the read-only store
   payload to its expected `steamapps/common` path, force DXMT native via
   `WINEDLLOVERRIDES`, set `SteamAppId` so a non-enforcing `steam_api` can init
   offline, then exec the exe. No Steam, no net.

**Which tier is it? (the boundary condition).** The hermetic launch works only if
the game is DRM-free at launch (§1 table, row 1) — discovered by trying step 3.
If the exe is SteamStub-encrypted or gates on a live ownership check (row 2), a
static store copy can't run and we do **not** emulate Steam to defeat that; those
titles set `runnerConfig.launchViaSteam = true` (the honest non-hermetic fallback:
`wine steam.exe -applaunch <appId>` with the user's own login) — the same
irreducible per-user boundary as Minecraft's MS-auth token, just heavier.

Acceptance criteria:

- After provision + capture, `nix run .#meccha-chameleon` launches from the
  content-addressed store payload with **no Steam running**, rendering via
  DXMT/Metal. (If it can't, it's a row-2 DRM title → `launchViaSteam` fallback.)
- Relaunch reuses the prefix; winetricks verbs are not re-applied.
- `hc-check` reports Steam `buildid` drift vs the pinned `versions` entry.
- The environment (wine + DXMT + verbs) rebuilds deterministically; the game
  payload is content-addressed and reproducible from the per-user hash.

Refs: [Sodium on Modrinth](https://modrinth.com/mod/sodium) ·
[Sodium installation wiki](https://github.com/CaffeineMC/sodium/wiki/Installation).

---

## 10. Prior art to reuse

`nix-minecraft` (Infinidoge) · `packwiz` / `packwiz2nix` · `portablemc` ·
`mac-app-util` (hraban) · nixpkgs `retroarch` + cores · `pkgs.formats` ·
`makeBinaryWrapper` / `symlinkJoin` · frankea/Whisky (artifact source) ·
3Shain/DXMT.

---

## 11. Phased roadmap

Difficulty-ordered. Launch surfaces + settings-as-code are core features built
once in phase 1, not repeated per class.

1. **Core + `native`/`love2d`.** `mkGame`, `reconcile`, `mkAppBundle`,
   mac-app-util wiring, both launch surfaces, versions/compat validation — on
   the easiest class. Everything after is "just another runner."
2. **`emulator`.** RetroArch + cores + `requireFile` ROMs. Nearly free once the
   core exists; validates the `requireFile` path.
3. **`java` (Minecraft + mods).** Loader + packwiz mods; immutable skeleton /
   mutable saves. Validates the `mods` dimension.
4. **`wine` (Maccha).** The declarative prefix reconciler + layered stack. The
   novel, statefullest piece — last, against a stable core.

**Validation focus.** The §9 acceptance targets are phases 3 (`java`) and 4
(`wine`). So the practical order is: build the phase-1 core (proven quickly with
a throwaway `native`/`love2d` game), then jump straight to `java` and `wine` to
hit the two validation builds. `emulator` is optional along the way.

---

## 12. Open questions

- **Save compatibility across versions.** A shared `instanceDir` with the
  content symlink swapped by `play` is the usual want; the `known`-set guards
  "this save won't load on that version." Do we need per-version save dirs as an
  option?
- **winetricks purity.** Ship impure (runtime fetch) first, add FOD-seeded cache
  later — or do it up front?
- **GPTK licensing.** Apple GPTK needs a developer-login download; only viable
  as `requireFile`. Is frankea-Whisky's bundled wine sufficient to avoid GPTK
  entirely?
- **Multi-version `.app`s.** Generate one launcher honoring `play`, or per-version
  bundles ("Maccha 1.2.0" / "Maccha 1.3.1")?
- **Codename scope.** Lives under `experimental/` for now; promote if it proves
  out.
