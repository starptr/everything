# Whale — x86_64-linux container images from the M1

Builds container images for the k8s cluster (x86_64-linux nodes) and pushes them to
Docker Hub. `image-nix-artifacts { name, buildLayeredImageArg }` takes an application
plus how to build its image and produces two system-keyed targets: the **x86_64-linux
image** and a **per-host push-script**. See `outputs.nix`.

The flake profile lives at `flake-profiles/whale`; targets are referenced as
`./flake-profiles/whale#<target>`.

## How it works

- **Images are always `x86_64-linux`** (built from `imagePkgs`), regardless of the host
  driving the build. On the M1 they are built on **methanol**, the native x86_64-linux
  remote builder, via sodium's `nix.buildMachines` (see
  `venus/modules/nixos-darwin/sodium.nix`). Heavy deps come as x86_64 substitutes from
  cache.nixos.org (methanol fetches them directly); only the layered-image tar/gzip is
  actually built, natively on methanol.
- **Push-scripts and the auth dev-shell are host-native** (`x86_64-linux` and
  `aarch64-darwin`). On the Mac, `skopeo` runs natively and reuses the Mac's own
  `~/.config/containers/auth.json`; the `docker-archive` tarball is arch-agnostic, so
  native skopeo copies the x86_64 image fine.
- Pushed image digests are recorded under `exports/whale/digests/<name>.txt`.

## Devloop

One-time: long-lived registry auth (creds persist in `~/.config/containers/auth.json`):

```bash
nix develop ./flake-profiles/whale   # auth shell with the same skopeo the push uses
skopeo login docker.io
```

Iterate — edit an image's `contents` in `outputs.nix`, then build + push:

```bash
nix run ./flake-profiles/whale#whale-push-example   # builds the x86_64 image, pushes from the Mac
```

Build/inspect without pushing:

```bash
nix build ./flake-profiles/whale#packages.x86_64-linux.whale-example-image
nix develop ./flake-profiles/whale -c \
  skopeo inspect docker-archive:"$(nix eval --raw ./flake-profiles/whale#packages.x86_64-linux.whale-example-image)"
# -> "Architecture": "amd64", "Os": "linux"
```

## Prerequisite: the methanol remote builder

The M1 builds x86_64-linux by offloading to methanol, a native x86_64-linux box registered in
sodium's `nix.buildMachines` (reached over the LAN at `10.0.0.211` as the `remote-builder`
user). Apply the config with `darwin-rebuild switch --flake ./flake-profiles/system-sodium`;
methanol must be up and reachable for the build to proceed.

## Troubleshooting: build fails or can't reach the builder

x86_64-linux builds run on methanol, so a failure usually means methanol is down or
unreachable. Confirm it answers over SSH as the `remote-builder` user and that it's listed in
`/etc/nix/machines`. If methanol's own nix store is genuinely corrupt (`path '…' is not
valid`), repair it on methanol itself with `nix store verify` / `nix-store --repair-path`,
not from the Mac.
