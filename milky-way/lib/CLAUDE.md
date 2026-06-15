# milky-way/lib — Library Authoring Guide

Each file here is a reusable service constructor: a single `new(...)` that returns all of a
service's Kubernetes manifests as fields of one object (`deployment`, `service`, `ingress`,
`configMap`, …). `main.jsonnet` instantiates it as one named field and Tanka flattens every
field into the applied resource list.

**This guide assumes the scaffolding conventions in
`../environments/stage00/orion-system/CLAUDE.md`** (the `new()` + single-field pattern,
package-qualified imports, `local this = self`, the ephemeral toleration, where `Namespace`
objects belong, how secrets flow from sops). Read that first; this file adds the lib-internal
best practices that guide doesn't cover. Don't restate it here.

## Name codified config for what it actually is

The single most load-bearing naming decision in these libs is whether the config a lib codifies
is the **fully declarative config** of the running app, or merely the **initial seed** that the
app then takes ownership of and rewrites. These are very different contracts, and the value names
must make the difference obvious — otherwise a reader edits the ConfigMap expecting it to be the
source of truth, when in reality the running app overwrote it long ago.

**Decision rule — which kind do you have?**

- **Declarative (read-only) config.** The app reads its config from a read-only mount and never
  rewrites it; any mutable *state* it keeps goes to a separate writable path. Here the codified
  config **is** the source of truth — `tk apply` fully determines it. Name it plainly: `config`,
  `configData`, `secret`. Example: `ddns-updater.libsonnet` mounts its `config.json` Secret
  read-only at `/secret` and points the app there via `CONFIG_FILEPATH`, leaving `/updater/data`
  writable for runtime state (`updates.json`). The Secret is authoritative; no qualifier needed.

- **Seeded (runtime-writable) config.** The app rewrites its own config file in place at runtime,
  so the config must live on a writable PVC and the lib can only *seed* it once (only-if-empty).
  Here the codified config is **not** authoritative — after first boot the PVC copy diverges and
  wins. Name every value in the seed chain with an `InitialSeed` suffix so nobody mistakes it for
  the live config. Canonical example: `qbittorrent.libsonnet` uses `qbtConfInitialSeed` (the
  rendered `qBittorrent.conf` string), `configDataInitialSeed` (the ConfigMap `data` payload),
  and `configMapInitialSeed` (the ConfigMap object mounted as the `config-seed` volume).

  > `openclaw.libsonnet` follows the same seed *mechanism* but still uses the old generic names
  > (`config`, `configData`, `configMap`). That's the naming this convention is meant to fix —
  > prefer the qbittorrent naming for new libs, and rename openclaw's when next touched.

Keep the Kubernetes resource *name* stable when you rename Jsonnet values — e.g. the ConfigMap
stays `name + '-config'` even though the Jsonnet field is `configMapInitialSeed`. The field name
is for humans reading the lib; renaming it must not churn cluster resources. (Verify with
`tk diff` showing no change — a pure rename produces byte-identical manifests.)

## The runtime-writable-config seed pattern

When you do have seeded config, the mechanics are shared across `qbittorrent.libsonnet` and
`openclaw.libsonnet` — copy them rather than reinventing:

1. **Render the config into a ConfigMap**, kept in a `local` so the same value feeds both the
   ConfigMap `data` and the pod-template checksum (below).
2. **An `init-config` init container seeds only-if-empty.** It mounts the ConfigMap read-only
   (e.g. at `/seed` or `/config`) and the PVC writable, then copies *only when the target is
   missing or empty* so runtime edits survive restarts:
   ```sh
   [ -s /config/qBittorrent/qBittorrent.conf ] \
     || cp /seed/qBittorrent.conf /config/qBittorrent/qBittorrent.conf
   ```
3. **`strategy: { type: 'Recreate' }`** on the Deployment, because an RWO (`ReadWriteOncePod`)
   config PVC means the old pod must release the volume before the new one can mount it.
4. **A `checksum/config` pod-template annotation** hashing the seed data
   (`std.md5(std.manifestJsonEx(configDataInitialSeed, ''))`). ConfigMap/subPath mounts don't
   live-update and editing a ConfigMap doesn't roll a Deployment on its own; hashing the seed
   into the template makes a seed change roll the pod so a *fresh* PVC picks up the new seed.

Document the seed-vs-live distinction in a comment at the top of the constructor, as both libs
do — it's the thing a future reader is most likely to get wrong.

## Single source of truth, asserted at the wiring points

Derive related values from one place instead of repeating literals, and assert the links so a
future typo becomes an evaluation error, not a silently broken manifest. Use `local this = self`
to cross-reference resources, and the helpers in `utils.libsonnet`:

- `utils.assertEqualAndReturn(got, expected)` — returns `got` after asserting equality. Use it
  where one manifest reads another's value: a Service `targetPort` reads the container's port
  *name* and asserts it equals `'webui'`; an Ingress `backend.port.number` reads and asserts the
  Service port. See `ddns-updater.libsonnet` / `qbittorrent.libsonnet` for both.
- `utils.assertAndReturn(value, predicate, message?)` — same idea for non-equality checks (e.g.
  asserting a container/env entry is the one you expect before indexing into it, as in
  `calibre-web-automated.libsonnet`).

Drive pod labels and Service selectors off one `spec.selector.matchLabels`
(`{} + this.deployment.spec.selector.matchLabels`) so they can't drift apart.

## Pin images by digest, default from `images.libsonnet`

Give every service a default `image` parameter, and make that default resolve to an **immutable
digest**, never a floating tag.

- **Our own (whale-built) images:** the default should come from `images.libsonnet` — never
  hand-write the digest. Default the param to
  `images["<name>"].fullyQualifiedImageReferencePinned`, exactly as
  `test-example-whale-image-digest.libsonnet` does:
  ```jsonnet
  local images = import 'milky-way/lib/images.libsonnet';
  // ...
  image=images["example-image"].fullyQualifiedImageReferencePinned,
  ```
  Those digests are read from `exports/whale/digests/<name>.txt` (written by
  `nix run ./flake-profiles/whale#whale-push-<name>`), so the pin tracks the build automatically
  — when you push a new image, the default updates with it. To onboard a new whale image, add it
  to the `raw` map in `images.libsonnet`.
- **Third-party images with a known digest:** centralize them in `images.libsonnet` too — add a
  `raw` entry whose digest is a `{ hash, tagHint? }` object and default the param to
  `images["<name>"].fullyQualifiedImageReferencePinned`. `hash` (`sha256:…`) is what's enforced;
  the optional `tagHint` (e.g. `v3.41.1`) is folded back in for readability, rendering
  `repo:tagHint@sha256:…`. An image shared by several consumers (e.g. `traefik/whoami` across the
  tailscale smoke tests) uses one `digestFor<Consumer>` object per consumer →
  `images.whoami.fullyQualifiedImageReferencePinnedFor<Consumer>`.
- **Third-party images without a digest (tag-only):** still centralize them in `images.libsonnet`
  rather than inlining a bare tag string — add a `raw` entry and default the param to its derived
  reference. A single-service image uses `defaultTag` →
  `images["<name>"].fullyQualifiedImageReferenceTagged`; an image shared by several services at
  (possibly) different versions (e.g. `busybox` used as an init/helper image) gets one
  `tagFor<Consumer>` property per consumer →
  `images.busybox.fullyQualifiedImageReferenceTaggedFor<Consumer>`. These tagged references are
  **DEPRECATED** — they exist to migrate off inline tag strings and to give one editing point per
  image; prefer a real digest pin whenever one is available. (When no tag is specified upstream,
  use `latest`, matching Kubernetes' default.)

## Never default a `tailscaleHostname` parameter

A `tailscaleHostname` parameter must **never** have a default value — make it required so every
caller passes one explicitly. The value becomes the proxy's tailnet device name (via the
`tailscale` ingressClass / `tailscale` loadBalancerClass), and a tailnet MagicDNS name **must be
unique across the whole tailnet**. A default invites two services to silently request the same
hostname; Tailscale resolves the collision by appending `-1`/`-2`/… to the *later* registrant, so
its URL silently shifts (e.g. `qbittorrent.<tailnet>.ts.net` → `qbittorrent-1.<tailnet>.ts.net`)
and the original name can stop resolving entirely. A required parameter turns "did you pick a
unique name?" into a question the caller is forced to answer at the wiring point, instead of a
default that's correct only as long as exactly one caller uses it.

This applies to L4 (`mopidy`/`sftp`-style raw `tailscale` LoadBalancer Services) and L7
(`qbittorrent`/`openclaw`-style `tailscale` Ingresses) alike. Several existing libs still default
it (`qbittorrent.libsonnet`, `openclaw.libsonnet`, `sftp.libsonnet`, the two
`test-tailscale-operator-*` libs) — fix those to required when next touched, and don't copy the
pattern into new libs.

### Migrating an exposure: let the old finalizer finish before creating the new one

Even a *unique* hostname collides with **itself** during a migration that moves a `tailscale`
Ingress/Service (e.g. to a new namespace or a renamed object). The operator deletes a proxy's
tailnet device in the `tailscale.com/finalizer` that runs on the **old** object's deletion; until
that finalizer completes, the old device still holds the name. If the **new** object is created
first (or concurrently), its proxy registers while the old device is still present, Tailscale
appends `-1`, and the old name stops resolving once the old device is finally reaped — exactly how
`qbittorrent` became `qbittorrent-1`.

So a migration must be **delete-old-then-create-new**, not a single `tk apply` that does both at
once (Tanka applies the whole environment, so a rename creates the new object before the old one's
finalizer has run). Sequence it by hand:

```sh
kubectl delete ingress <old-name> -n <old-ns>   # blocks until the finalizer reaps the device
tailscale status | grep <hostname>              # confirm the device is gone (name is free)
# only now apply the environment that creates the new Ingress/Service
nix develop ./flake-profiles/milky-way-devenv --impure -c bash -c \
  'cd milky-way && tk apply environments/stage00/orion-system --auto-approve=always'
```

This same sequence is how a `-1` name is recovered after the fact: delete the live Ingress to free
the name, confirm the device is gone, then re-apply to recreate it cleanly.

## Builders vs. service libs

Most libs return a full service (Deployment + Service + Ingress). A few are **builders** that
return embeddable *fragments* instead — `gluetun.libsonnet` returns `{ containers, volumes,
secret, configMap }` that a host lib (qbittorrent) splices into its own pod so the two share one
network namespace. If you write a builder, say so loudly in the header comment (gluetun's first
line is "this does NOT return a Deployment"), since it breaks the one-file-one-service expectation.

## Comment the *why*, not the *what*

These libs carry unusually dense comments, and that's deliberate — they encode hard-won cluster
facts and non-obvious trade-offs (the killswitch allowlist CIDRs, why `securityContext.sysctls`
is forbidden on methanol, why config is seeded rather than mounted). Match that altitude: explain
the constraint or the reason a line exists, not the syntax. A reader can see *what* a field is;
they can't recover *why* it has to be that value.
