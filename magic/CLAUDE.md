# magic — shared constants & public keys

`magic/` holds small, cross-cutting values that several projects in this monorepo need to
agree on, so they live in one place instead of being copy-pasted. Today that's:

- `magic/common/constants.nix` — home-relative path strings and other Nix constants.
- `magic/common/public_keys.json` — the single source of truth for reusable **public keys**.
- `magic/home-manager/` — a home-manager wrapper around `common/constants.nix`.

## Public keys: `magic/common/public_keys.json`

All reusable public keys live here, keyed by category then by a descriptive camelCase name:

```json
{
  "ssh": {
    "yutoSodium": "ssh-rsa AAAA… yuto@Yutos-MacBook-Pro.local",
    "onePasswordMain": "ssh-ed25519 AAAA…",
    "magnesiumHydroxideForGrandCentral": "ssh-ed25519 AAAA… grand-central yuto.nishida@magnesium-hydroxide",
    "sodiumForGrandCentral": "ssh-ed25519 AAAA… grand-central-tunnel-sodium"
  }
}
```

Each value is the **full** key line exactly as it belongs in an `authorized_keys` file
(including any trailing comment field). Never paste a public key literal into another file —
add it here once and reference it.

### Consume from Nix

`constants.nix` re-exports the parsed JSON as `publicKeys`:

```nix
# constants.nix:
publicKeys = builtins.fromJSON (builtins.readFile ./public_keys.json);
```

In a module that already receives `lib` (any NixOS / nix-darwin module does), import it and
reference a key — e.g. the venus host modules under `venus/modules/nixos-darwin/*.nix`:

```nix
let
  publicKeys = (import ../../../magic/common/constants.nix { inherit lib; }).publicKeys;
in {
  users.users.yuto.openssh.authorizedKeys.keys = [
    publicKeys.ssh.yutoSodium
    publicKeys.ssh.onePasswordMain
  ];
}
```

If a module doesn't take `lib`, pass `{ lib = pkgs.lib; }` instead (e.g. `sodium.nix`,
`aluminum-nitride.nix`). Access is lazy: only `publicKeys` is forced, not the rest of
`constants.nix`.

### Consume from jsonnet (milky-way / Tanka)

`magic/` is symlinked into milky-way's jsonnet library path as
`milky-way/vendor/magic -> ../../magic` (the same mechanism as the existing
`vendor/exports -> ../../exports`). That makes the repo-root `magic/…` importable by path:

```jsonnet
local pubkeys = import 'magic/common/public_keys.json';
// …
authorizedKeys = [
  pubkeys.ssh.yutoSodium,
  pubkeys.ssh.onePasswordMain,
],
```

`import` parses JSON natively. If a fresh checkout is missing the symlink, recreate it with
`ln -s ../../magic milky-way/vendor/magic` (it is committed, and `jb` only manages
`vendor/github.com/`, so it won't be disturbed).

### Adding a key

1. Add the full key line under the right category in `public_keys.json` with a descriptive name.
2. Reference it via `publicKeys.ssh.<name>` (Nix) or `pubkeys.ssh.<name>` (jsonnet).

### Scope & deliberate exceptions

This registry currently holds **SSH keys only**. Two key kinds are intentionally *not* sourced
from here because their consuming tools cannot import JSON:

- **Cachix / nix binary-cache keys** in flakes' `nixConfig` — a flake's `nixConfig` is
  evaluated per-flake and can't `readFile` outside its own directory. They stay as literals
  in each `flake.nix`.
- **age / sops recipients** in `.sops.yaml` — the `sops` CLI reads `.sops.yaml` directly; the
  per-file headers are auto-generated mirrors of it. They stay in `.sops.yaml` (already the
  single place they're authored).

Keys under `tilderef/keys/` are also out of scope and are managed there.
