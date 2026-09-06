# yutobot-discord

Yuto's personal Discord bot (`discord.js` v12): canvas-rendered welcome/wii-menu cards, an
owoifier, and simple call/response commands. **Outbound-only** — it opens a gateway websocket to
Discord and runs no inbound server. Migrated off an old CapRover droplet to the milky-way k8s
cluster; built reproducibly with Nix and run as a single-replica Deployment.

## What changed from the upstream (`starptr/yutobot-discord`) on migration

The source was copied in as-is except for the minimal fixes needed to build reproducibly and run
on a current Node:

- **Runs directly on Node (no babel).** Upstream's `build`/`deploy` scripts ran `babel`, but there
  was no babel config, so it was a no-op copy over already-plain CommonJS. Dropped the babel
  scripts + devDeps; the entrypoint is `node src/index.js`.
- **`canvas` bumped `^2.8.0` → `^3`.** Node 20 was removed from nixpkgs on EOL; on Node 22 the
  nan-based canvas 2.x doesn't compile, while canvas 3.x (Node-API) does. The 3.x API is a drop-in
  for the `registerFont`/`loadImage`/`createCanvas` calls in `src/modules/wiimenu`.
- **`wiimenu` assets are `__dirname`-relative, not CWD-relative.** Upstream loaded the font + png
  as `./assets/...` (relative to the process CWD). Under Nix the app runs from a store path and the
  container's CWD holds only the mounted `.env`, so those paths now resolve via
  `path.resolve(__dirname, '../../../assets/...')` (the store copy).
- Dropped the CapRover deploy cruft: `Dockerfile`, `docker-compose.yml`, `.github/` CI,
  `.dockerignore`, `yarn.lock` (replaced by `package-lock.json` for `buildNpmPackage`).

The commented-out `tweeter`/`vcsyncwarn` modules and their env vars (`TWITTER_*`,
`DISCORD_USER_*`, `DISCORD_CHANNELID_{STREAM,VC_GRAVEYARD}`) are inactive but were kept for parity.

## Build & run

```bash
nix build ./yutobot-discord          # the app (buildNpmPackage; wrapper at result/bin/yutobot-discord)
nix develop ./yutobot-discord        # dev shell (node 22)
```

`Cargo.lock`-equivalent: `package-lock.json` + `flake.lock` are committed. Bumping deps means
regenerating `package-lock.json` (`npm install --package-lock-only`) and refreshing `npmDepsHash`
in `flake.nix` (set it to `lib.fakeHash`, build, copy the reported hash back).

Container image: `nix run ./flake-profiles/whale#yutobot-discord-push` — builds the x86_64-linux
image (`whale/outputs.nix`), pushes to `docker.io/yuto7/yutobot-discord`, and writes the digest to
`exports/whale/digests/yutobot-discord.txt`. The build runs **natively on methanol** (the x86_64
remote builder), not under emulation.

## Configuration (env vars)

The app reads its config with `dotenv.config()`, which loads `.env` from the process CWD. Active
vars: `DISCORD_BOT_TOKEN`, `DISCORD_COMMAND_PREFIX`, and the channel IDs `DISCORD_CHANNELID_{WELCOME,
VC_SYNC,COMMANDS,SPAWN,README,GENERAL}`. All values live in the sops-managed `.env` (see below).

## Deployment (where everything lives)

Touch these together when changing how it's deployed:

- **k8s manifests**: `milky-way/lib/yutobot-discord.libsonnet` (Secret + Deployment), wired in
  `milky-way/environments/stage00/orion-system/main.jsonnet` (the `yutobotDiscord` field).
- **image build**: `whale/outputs.nix` (the `yutobot-discord` target) + the flake input in
  `flake-profiles/whale/flake.nix`; digest pinned in `milky-way/lib/images.libsonnet`.
- **secret (sops)**: `secrets/discord/yutobot.env` — the whole `.env` as a binary blob. Rule in
  `.sops.yaml`; decrypted on sodium by sops-nix (`venus/modules/home-manager/sodium.nix`, the
  `discord/yutobot.env` entry) and imported into the Secret via `milky-way/secrets.libsonnet`. The
  image sets `WorkingDir=/app`; the lib mounts the file at `/app/.env` where `dotenv` reads it.

## Operational note

**Singleton.** `replicas: 1` + `Recreate` — two pods would each hold a live bot session and
double-handle every Discord event. A bot token allows multiple concurrent gateway connections, so
when cutting over from another host (e.g. the old CapRover instance), **stop the old instance** or
both will respond to the same events.
