# eight/ — DNS records (octodns → Cloudflare)

`eight/` defines DNS records as Nix, renders them to octodns YAML, and reconciles them to
Cloudflare with [octodns](https://github.com/octodns/octodns).

## Layout

- `per-domain/<domain>.nix` — the records for one zone. Each is a function
  `{ configurations-by-file, generated }: { <label> = <record>; }` where the attribute key
  is the subdomain label (`""` is the apex/root) and the value is the record attrset.
- `octodns-config.nix` — assembles the per-domain files into the octodns config directory
  (including `production.yaml`, the octodns manager config).
- `outputs.nix` — exposes the flake packages `eight-configurations`, `eight-dry-run`, and
  `eight-wet-run` (octodns with the Cloudflare provider).

## Record format

A record is an attrset with `type`, `ttl`, a `value` (or `values` for multi-value records
like `MX`), and an `octodns` block. Most records set `octodns.cloudflare.auto-ttl = true`;
add `octodns.cloudflare.comment` for a note in the Cloudflare UI.

```nix
  "grand-central" = {
    octodns = {
      cloudflare = {
        auto-ttl = true;
      };
    };
    ttl = 300;
    type = "CNAME";
    value = "carless-drivers-ddns.andref.app.";
  };
```

**CNAME / MX / other FQDN targets take a trailing dot** (e.g.
`carless-drivers-ddns.andref.app.`). `A` records use a bare IP. Some `value`s are computed
from `generated.<host>.ipAddress`.

## Build & inspect

```sh
nix build ./flake-profiles/everything-devenv#eight-configurations
```

This points the repo-root `result/` symlink at the rendered config directory. Inspect the
relevant zone, e.g. `result/yuto.sh.yaml`, to confirm a record rendered as expected before
pushing.

## Reconcile to Cloudflare

The reconciler needs `$CLOUDFLARE_TOKEN`. That secret is provided by the `#jupiter` dev
shell (it loads `.env.jupiter`), so run the commands **inside that shell**. The
`CLOUDFLARE_TOKEN=$CLOUDFLARE_TOKEN` prefix is required because `nix run` does not otherwise
forward the env var into the program's runtime.

Human flow — enter the shell once, then run the two commands:

```sh
nix develop ./flake-profiles/everything-devenv#jupiter --impure
# inside the shell:
CLOUDFLARE_TOKEN=$CLOUDFLARE_TOKEN nix run ./flake-profiles/everything-devenv#eight-dry-run
CLOUDFLARE_TOKEN=$CLOUDFLARE_TOKEN nix run ./flake-profiles/everything-devenv#eight-wet-run
```

Agent flow — wrap each invocation so the dev-shell environment is present:

```sh
nix develop ./flake-profiles/everything-devenv#jupiter --impure --command \
  bash -c 'CLOUDFLARE_TOKEN=$CLOUDFLARE_TOKEN nix run ./flake-profiles/everything-devenv#eight-dry-run'

nix develop ./flake-profiles/everything-devenv#jupiter --impure --command \
  bash -c 'CLOUDFLARE_TOKEN=$CLOUDFLARE_TOKEN nix run ./flake-profiles/everything-devenv#eight-wet-run'
```

`eight-dry-run` runs `octodns-sync` (preview only); `eight-wet-run` adds `--doit` to apply.
**Always dry-run first** and confirm the plan contains only the intended change before the
wet run. If Cloudflare returns `CloudflareError: Invalid request headers`, `$CLOUDFLARE_TOKEN`
is empty or invalid — fix the secret rather than retrying.
