# Whale — x86_64-linux container images from the M1

Builds container images for the k8s cluster (x86_64-linux nodes) and pushes them to
Docker Hub. `image-nix-artifacts { name, buildLayeredImageArg }` takes an application
plus how to build its image and produces two system-keyed targets: the **x86_64-linux
image** and a **per-host push-script**. See `outputs.nix`.

The flake profile lives at `flake-profiles/whale`; targets are referenced as
`./flake-profiles/whale#<target>`.

## How it works

- **Images are always `x86_64-linux`** (built from `imagePkgs`), regardless of the host
  driving the build. On the M1 they are realized via sodium's emulated `linux-builder`
  (QEMU binfmt — see `venus/modules/nixos-darwin/sodium.nix`). Heavy deps come as
  x86_64 substitutes from cache.nixos.org; only the layered-image tar/gzip step is
  emulated, so storage/CPU stay modest.
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

## Prerequisite: x86_64 emulation on the builder

The M1 builds x86_64-linux because sodium's `nix.linux-builder` advertises
`x86_64-linux` with `boot.binfmt.emulatedSystems = ["x86_64-linux"]`. Apply with
`darwin-rebuild switch --flake ./flake-profiles/system-sodium`.

## Troubleshooting: `path '…' is not valid`

If a build fails with `path '…-…json' is not valid` / `builder failed with exit code 1`,
the linux-builder VM's nix store is corrupted (a truncated path that nix still marks
"valid", so re-copies skip it; `repair-path` isn't reachable via the guest daemon). The
classic trigger is a truncated `binfmt_nixos.conf`, which silently disables x86_64
emulation. Reset the builder's persistent disk (keys are preserved):

```bash
nix run ./flake-profiles/system-sodium#reset-linux-builder
```

This stops the service, removes `/var/lib/linux-builder/nixos.qcow2`, restarts it, and
verifies `/proc/sys/fs/binfmt_misc/x86_64-linux` is registered after reboot.
