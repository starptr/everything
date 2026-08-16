# orion-system Environment Guide

Tanka environment for the **Methanol** cluster (k3s on NixOS). `main.jsonnet` is the single
entrypoint: it evaluates to one flat object whose every field is a Kubernetes manifest (or a
sub-object of manifests). Tanka flattens that object into the resource list it applies.

This guide covers **how to add a new service to `main.jsonnet`**. For `tk`/`kubectl`/SSH
commands and cluster access, see the parent `milky-way/CLAUDE.md`.

## The pattern: a `lib/` constructor + one field in `main.jsonnet`

A service is **not** written inline in `main.jsonnet`. Define it as a reusable constructor in
`milky-way/lib/<service>.libsonnet`, then instantiate it as a single named field here. This
keeps `main.jsonnet` a readable manifest of *what runs*, with the *how* factored out.

Existing examples to copy from, in rough order of complexity:
- `milky-way/lib/http-echo.libsonnet` — Deployment + Service + Ingress. The canonical
  template for a stateless web service.
- `milky-way/lib/ddns-updater.libsonnet` — adds a Secret built from a passed-in config and
  mounted read-only. Copy this when the service needs config/credentials.
- `milky-way/lib/calibre-web-automated.libsonnet` — StatefulSet with `volumeClaimTemplates`
  for persistent storage.

### Writing the constructor

```jsonnet
local utils = import 'milky-way/lib/utils.libsonnet';

{
  new(
    requiredArg,                 // positional, no default — caller must supply
    name='my-service',
    namespace='default',
    image='org/image',
    port=8080,
  ):: {
    local this = self,           // lets resources reference each other by field

    deployment: { /* apps/v1 Deployment */ },
    service:    { /* v1 Service */ },
    ingress:    { /* networking.k8s.io/v1 Ingress */ },
  },
}
```

Conventions baked into the existing libs — follow them:

- **Imports are package-qualified**, never relative: `import 'milky-way/lib/utils.libsonnet'`,
  not `'../lib/...'`. The repo root is on the Jsonnet library path.
- **`local this = self`** at the top of the returned object, so the Service can reference
  `this.deployment.spec.template.metadata.labels`, the Ingress can reference
  `this.service.metadata.name`, etc. Derive values from one source of truth rather than
  repeating literals.
- **Assert invariants with `utils.assertEqualAndReturn(got, expected)`** (from
  `lib/utils.libsonnet`) when wiring resources together — e.g. a Service `targetPort` should
  read the container's port *name* and assert it equals `"webui"`. This turns a future typo
  into an evaluation error instead of a silently broken manifest. `utils.assertAndReturn`
  takes a predicate for non-equality checks.
- **Node scheduling:** add the cluster's ephemeral-node toleration so the pod can schedule:
  ```jsonnet
  tolerations: [{ key: 'ephemeral', operator: 'Exists', effect: 'NoSchedule' }],
  ```
- **Ingress:** use `ingressClassName: 'traefik'` and set `spec.rules[0].host` to the desired
  domain (passed in as an arg). Traefik runs as a hostNetwork DaemonSet (see `traefikConfig`
  in `main.jsonnet`).
- **Labels:** drive the Service `selector` and pod labels off
  `spec.selector.matchLabels` (e.g. `{} + this.deployment.spec.selector.matchLabels`) so they
  can never drift apart.

### Registering it in `main.jsonnet`

1. Add a package-qualified import near the top, beside the other `lib` imports:
   ```jsonnet
   local myService = import 'milky-way/lib/my-service.libsonnet';
   ```
2. Add one field to the top-level object (group it near similar services). The field name is
   just a label for humans/diffs — the `metadata.name` inside the resources is what matters:
   ```jsonnet
   myService: myService.new(domain='my-service.local'),
   ```

That's it — Tanka picks up every field automatically. There is no separate registry list.

## Ingress & `.local` name resolution

Every service here is reached at a `<name>.local` host, and the whole request path is anchored to
the **methanol** node — *independent* of which node actually runs the pod. So a service's pod needs
no `nodeSelector`/`nodeAffinity` for its `.local` name to keep working; entry is fixed to methanol,
pod placement is free. The path:

1. **mDNS name → methanol's NIC.** `<name>.local` is published by an `avahi-publish-address` systemd
   service on methanol, bound to its physical interface (`enp42s0`) — a static address alias, not
   tied to the pod. Add a new name to `services.avahi-aliases.aliases` in
   `venus/modules/nixos-darwin/methanol.nix`; the publishing mechanism is
   `venus/modules/nixos-darwin/use-avahi-aliases.nix`.
2. **HTTP → hostNetwork Traefik.** Traefik runs as a hostNetwork DaemonSet (`traefikConfig` in
   `main.jsonnet`, defined in `lib/traefik.libsonnet`), so it listens directly on methanol's ports
   80/443. The Ingress `host` rule matches `<name>.local`.
3. **Traefik → ClusterIP → pod, anywhere.** The Ingress targets a ClusterIP Service; Cilium
   (`kubeProxyReplacement: true`, eBPF — see `charts.jsonnet`) load-balances that ClusterIP to the
   pod on whatever node it landed on. NFS-backed PVCs (`my-custom-zfs-generic-nfs-csi`) also mount
   from any node, so storage doesn't pin the pod either.

The one dependency is that **methanol itself is up**: it both publishes the name and receives the
traffic. If methanol is down the name is unreachable regardless of where the pod runs; if methanol
is up, the pod can be anywhere.

## Namespaces

Declare every `Namespace` as a top-level field directly in `main.jsonnet` — **never** create one
inside a `lib/` constructor. The top-level object is the single readable manifest of *what runs*;
keeping namespaces there means the full set of namespaces is visible in one place, and no service
constructor implicitly owns a namespace that other resources (or other services) share.

Existing examples in `main.jsonnet`:

```jsonnet
democraticCsiNamespace: {
  apiVersion: "v1",
  kind: "Namespace",
  metadata: { name: "democratic-csi" },
},
testingNamespace: {
  apiVersion: "v1",
  kind: "Namespace",
  metadata: { name: "test-k8s" },
},
```

A `lib/` constructor's resources reference their namespace by name (the `namespace:` field on
each manifest) and rely on the namespace declared here — they must not emit a `Namespace`
themselves.

## Secrets

Secrets must come from the sops-managed files in `milky-way/secrets/` — these are
**read-only symlinks** generated by sops-nix. Never inline a real credential into
`main.jsonnet` or a lib. To change a secret's *value*, edit the sops-nix source and rebuild;
do not edit the symlink.

Two established ways to get a secret into the cluster:

- **Construct a `Secret` manifest from a config object.** The constructor receives the config
  (with sensitive fields read from the secrets import) and base64-encodes it. ddns-updater
  does this — `new(config, ...)` renders `std.base64(std.manifestJsonEx(config, '  '))` into a
  `Secret`'s `data`, and the Deployment mounts it read-only. In `main.jsonnet`:
  ```jsonnet
  local secrets = import 'milky-way/secrets/k8s-secret-values.jsonnet';
  // ...
  ddnsUpdater: ddnsUpdater.new(
    config={ settings: [{ provider: 'cloudflare',
                          token: secrets.ddnsUpdater.cloudflare.token, /* ... */ }] },
    domain='carless-drivers.ddns.andref.app',
  ),
  ```
  (Use `std.manifestYamlDoc` instead of `manifestJsonEx` when the app wants YAML, as the
  democratic-csi driver-config secrets do.)
- **Reference an existing Secret by name** from a Helm chart's values
  (`existingConfigSecret: "..."`), for chart-based services defined in `charts.jsonnet`.

Prefer mounting a secret at a dedicated read-only path (e.g. `/secret`) and pointing the app
at it via env var, rather than overlaying a writable data directory — see the
`CONFIG_FILEPATH=/secret/config.json` setup in `ddns-updater.libsonnet`.

## Helm-based services

If the upstream ships a Helm chart, vendor it under `milky-way/charts/`, define it in
`milky-way/charts.jsonnet` via `helm.template(...)`, and reference it in `main.jsonnet` as
`myChart: charts.my_chart` (see `zfsIscsiDriver: charts.zfs_iscsi`). Use a hand-written lib
constructor only for plain manifests.

## Verify before and after applying

From the repo root (wrap in the devenv one-liner from `milky-way/CLAUDE.md`):

```bash
# 1. Render — confirms the lib + main.jsonnet evaluate and the new resources appear.
tk show environments/stage00/orion-system --dangerous-allow-redirect

# 2. Diff against the live cluster — a clean add shows only your new resources.
tk diff environments/stage00/orion-system

# 3. Apply.
tk apply environments/stage00/orion-system --auto-approve=always
```

Then confirm the workload is healthy:

```bash
kubectl --context methanol -n <namespace> get pods -l app=<name>
kubectl --context methanol -n <namespace> logs -l app=<name> --tail=50
```

For a secret-mounted config, spot-check that the rendered `Secret`'s base64 value decodes to
what you expect (`tk show ... | grep -A1 <name>` then `base64 -d`), and that the pod logs
show it read the config from the mounted path rather than erroring on parse/auth.

## Runbook: back-fill already-downloaded SeaDexArr episodes into Shoko

The qbittorrent on-complete hook hardlinks torrents carrying the `on-finish-hardlink-to-shoko-import`
tag (or in the `sonarr-for-sdxarr` category) into Shoko's drop source (`hardlinkOnFinished` in
`main.jsonnet`, handler in `lib/qbittorrent.libsonnet`). That only fires on *future* completions. To back-fill
SeaDexArr episodes downloaded before the hook covered `sonarr-for-sdxarr`, run this one-shot — it
enumerates completed torrents in that category via the local qBittorrent API (localhost needs no
creds: `LocalHostAuth=false` + `127.0.0.0/8` in `AuthSubnetWhitelist`) and hardlinks each into the
drop source, exactly like the hook. Idempotent (skips entries already present) and safe (same-fs
hardlink; the seeding originals are untouched):

```bash
kubectl --context methanol exec deploy/qbittorrent -c qbittorrent -- s6-setuidgid abc sh -c '
  set -eu
  mkdir -p /data/downloads/shoko-drop
  curl -fsS "http://127.0.0.1:8080/api/v2/torrents/info?category=sonarr-for-sdxarr&filter=completed" \
    | jq -r ".[].content_path" \
    | while IFS= read -r p; do
        [ -n "$p" ] || continue
        dest="/data/downloads/shoko-drop/$(basename "$p")"
        [ -e "$dest" ] && continue
        cp -al "$p" /data/downloads/shoko-drop/ && echo "linked: $p"
      done
'
```

**Run it as `abc` (`s6-setuidgid abc`), NOT a bare `kubectl exec`.** A bare exec runs as **root**,
which the shared NFS root-squashes to `nobody` — then `cp -al` on a *multi-file* (season-pack)
torrent creates the destination directory as `nobody:0700` and can't chown it, so Shoko (uid 1000)
can't traverse it and the season is invisible to Shoko. Running as `abc` (uid 1000 — the same uid
the qbittorrent process and the go-forward hook use) creates `abc:users` dirs Shoko can organize.
Single-file torrents are unaffected either way (a hardlink keeps the inode's `abc` ownership), so a
mistaken root run leaves only the directory torrents broken; re-run as `abc` after `rm -rf`-ing the
`nobody`-owned dirs (as root, which owns them) to fix.

Shoko then drains the drop source into `/data/library/Anime (Shoko)` on its own schedule; a large
batch is paced by AniDB UDP throttling, so let it run and watch Shoko's WebUI queue. (Precondition:
Shoko must already have `/data/downloads/shoko-drop` set as a Drop Source import folder with a drop
destination + renamer configured — the same setup the tag-driven Shoko-import workflow needs.)
