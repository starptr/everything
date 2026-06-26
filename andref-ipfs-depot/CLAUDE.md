# andref-ipfs-depot

A Discord-gated file uploader for the self-hosted **kubo** (IPFS) node. A member of a specific
Discord guild runs `/upload`; the bot replies (ephemerally) with a single-use link; the user opens
it, picks a file, and submits; the backend streams the file into kubo **pinned**, and returns the
direct subdomain-gateway link — which the bot also posts back into the channel.

This is a single Rust binary (built reproducibly with crane/Nix) that runs **both** the Discord bot
and the HTTP server in one process. The deployment lives across several other parts of this monorepo
(see [Deployment](#deployment-where-everything-lives)).

## Request flow

```
/upload (guild)  ──►  bot mints single-use token, replies ephemerally:
                       https://depot.andref.app/u/<token>
user opens link  ──►  GET /u/<token>  (token validated, NOT consumed → serves the upload page)
Submit           ──►  POST /api/upload/<token>  (token consumed; file streamed → kubo)
                       kubo /api/v0/add?pin=true&cid-version=1   (bearer: scoped depot token)
                 ◄──  https://<cid>.ipfs.andref.app   (returned to page + posted to the channel)
```

## Architecture & why

- **One process, one binary.** The bot *mints* tokens and the HTTP handler *validates/consumes*
  them, sharing an in-memory `TokenStore` (`Arc`). Splitting them would force a networked store
  (Redis/DB) — more deps, more failure modes. So they live together: serenity client + axum server
  on one tokio runtime (`main.rs`, joined with `tokio::try_join!` + graceful SIGTERM). Consequence:
  the Deployment is **`replicas: 1` + `Recreate`** (two pods would each hold a *different* token
  store), and there is **no PVC** — the store is disposable (lost on restart; a member just re-runs
  `/upload`).
- **Uploads stream straight through to kubo — never buffered.** A task reads the multipart field and
  forwards chunks over a bounded `mpsc` channel (which also back-pressures the client); reqwest sends
  that as the request body to kubo. Memory stays flat (tens of MB) regardless of file size, so the
  pod limit is a modest **256Mi**. Do **not** revert to buffering (`field.bytes()`) — a multi-GB
  upload would OOM the pod.
- **Tokens: single-use + 15-min TTL, lazy expiry** (`tokens.rs`). `consume()` removes the token
  (single use, enforced at upload). `is_valid()` is a **non-consuming** peek used only to gate the
  page (`GET /u/<token>`), so a guessed/expired/used link shows a 404 page instead of the form,
  without burning a live token before its upload.
- **`cid-version=1` is required.** The result URL is `<cid>.ipfs.andref.app`; a CIDv0 (`Qm…`,
  base58, case-sensitive) is not a valid DNS label, so kubo must return a base32 CIDv1.
- **Least-privilege kubo access.** The backend holds a bearer token kubo's `API.Authorizations`
  scopes to **only `/api/v0/add`** (`add` with `pin=true` both stores and pins). kubo's RPC is
  ClusterIP-only and never exposed publicly; the browser never sees the token.
- **Frontend is embedded** (`include_str!`, see `assets.rs`), so the container ships nothing but the
  binary. The page uses `XMLHttpRequest` for real upload progress (`Uploading… N%` → `Pinning…`).
- **No privileged gateway intents** — slash commands arrive regardless (`GatewayIntents::empty()`).
  The bot does need the `bot` + `applications.commands` scopes and **Send Messages** to post results.

## Module layout (`src/`)

| File | Responsibility |
|---|---|
| `main.rs` | load config; build serenity client; clone its `Arc<Http>` into `AppState`; insert state into the TypeMap; run bot + axum together with graceful shutdown |
| `config.rs` | `Config::from_env()` — fail-fast on missing vars |
| `state.rs` | `AppState { cfg, kubo: reqwest::Client, discord: Arc<Http>, store }` + the serenity `TypeMapKey` |
| `tokens.rs` | `TokenStore`: `issue` / `consume` (single-use) / `is_valid` (non-consuming page gate) |
| `discord.rs` | register guild `/upload`; on invoke mint a token bound to channel+user, reply ephemerally |
| `web.rs` | axum routes; gated page; streaming upload → kubo; post result to channel |
| `ipfs.rs` | the one kubo RPC call (`add`, streaming multipart) + gateway-URL builder |
| `assets.rs` | `include_str!` the `assets/` frontend (index/invalid html, css, js) |

Tests (`cargo nextest`, run by `nix flake check`): token semantics in `tokens.rs`, page gating in
`web.rs`.

## Configuration (env vars)

`DISCORD_BOT_TOKEN`, `DISCORD_GUILD_ID`, `KUBO_RPC_BASE` (e.g.
`http://kubo.default.svc.cluster.local:5001`), `KUBO_RPC_TOKEN` (the scoped depot token),
`GATEWAY_BASE_DOMAIN` (`ipfs.andref.app`), `APP_BASE_URL` (`https://depot.andref.app`), `BIND_ADDR`
(`0.0.0.0:8080`). All required.

## Build, test, image

```bash
nix flake check ./andref-ipfs-depot      # build + clippy(-Dwarnings) + fmt + taplo + deny + audit + nextest
nix build ./andref-ipfs-depot            # the binary
nix develop ./andref-ipfs-depot -c cargo …   # dev shell (cargo/clippy/taplo/nextest/cargo-deny)
```

- `Cargo.lock` and `flake.lock` are committed (crane requires the lock for reproducible builds).
- `deny.toml` allows the standard permissive license set + a `ring` clarification.
- `.cargo/audit.toml` ignores four `rustls-webpki 0.102` advisories — they're only in serenity's
  websocket TLS stack (reqwest already uses the patched 0.103) and are unfixable until serenity bumps
  rustls. Drop them when it does.
- Container image: `nix run ./flake-profiles/whale#andref-ipfs-depot-push` — builds the
  x86_64-linux image (see `whale/outputs.nix`) and pushes to `docker.io/yuto7/andref-ipfs-depot`,
  writing the digest to `exports/whale/digests/andref-ipfs-depot.txt`. The build runs **natively on
  methanol** (an x86_64 remote nix builder, configured in `venus/modules/nixos-darwin/sodium.nix`),
  not under QEMU emulation; the push still runs locally with local skopeo creds.

## Deployment (where everything lives)

The app's runtime config is spread across the monorepo — touch all of these together when changing
how it's deployed:

- **k8s manifests**: `milky-way/lib/andref-ipfs-depot.libsonnet` (Secret/Deployment/Service +
  public Traefik Ingress + cert-manager Certificate), wired in
  `milky-way/environments/stage00/orion-system/main.jsonnet` (the `andrefIpfsDepot` field).
- **kubo scoped token**: `milky-way/lib/kubo.libsonnet` — the optional `depotRpcToken` adds the
  third `API.Authorizations` grant scoped to `/api/v0/add`.
- **image pin**: `milky-way/lib/images.libsonnet` (`andref-ipfs-depot`, reads the digest file).
- **public DNS**: `eight/per-domain/andref.app.nix` — `depot` CNAME → home-IP DDNS target.
- **secrets (sops)**: `k8s-secret-values.jsonnet` — `kubo.rpcTokenForAndrefIpfsDepot`,
  `discord.andref.guildId`, `discordBots.andrefIpfsDepot.token`.

Apply order: kubo grant (`tk apply … -t '.*kubo.*'`, scoped so it doesn't re-roll cilium/hubble
certs) → DNS → the app. Local smoke test: run the binary with env pointed at a port-forwarded kubo
(`kubectl -n default port-forward svc/kubo 5001:5001`).

## Operational gotchas

- **Traefik read timeout caps upload duration.** Traefik v3 defaults
  `respondingTimeouts.readTimeout` to **60s**, which covers reading the *entire* request body — so
  any upload taking >60s is severed mid-stream (502 / "Bad Gateway"), which is every multi-GB file.
  This is fixed by `readTimeout: '0s'` on the websecure entrypoint in
  `milky-way/lib/traefik.libsonnet`. If uploads start dying at ~60s again, check that setting and
  that Traefik actually rolled (`kubectl -n kube-system get ds traefik -o jsonpath=… | grep readTimeout`).
- **Discord won't embed large videos.** kubo serves the right `Content-Type` (it content-sniffs —
  e.g. a WebM is served `video/webm` with range support), but Discord only embeds *modestly-sized*
  media (tens of MB), so a multi-GB video just shows as a link no matter what.
- **No filename/extension in the result URL (known limitation).** The backend sends kubo a generic
  `"file"` name, so the link is `<cid>.ipfs.andref.app/` with no extension. Discord's inline media
  player keys off a media extension in the URL path, so even small videos won't embed as-is. To fix:
  preserve the original filename (frontend sends it) and `wrap-with-directory=true` so the URL is
  `<dir-cid>.ipfs.andref.app/<name>.ext` — a real extension Discord recognizes, plus a nicer
  download name. Not yet implemented.
- **Upload size ceiling** is the axum `DefaultBodyLimit` (8 GiB) in `web.rs`, also effectively
  bounded by kubo's repo PVC (10Gi); grow both together.
