# owl

Turn a code checkout into a browsable, almost-static website — one page per
source file, Sourcegraph-lite. Each file has **two views**:

- **raw** — syntax-highlighted source with `#L` line anchors.
- **rendered** — the same source, but runs of multi-line comments are lifted into
  markdown prose boxes, and `.md` files are rendered in full.

The output is plain static HTML deployable on any static host (Cloudflare Pages,
Netlify, GitHub Pages, S3, …).

## Architecture

Two decoupled components, composed by the flake:

```
checkout ─▶ owl-filter (Rust/globset) ─▶ pruned tree ─▶ owl-web (Astro/Shiki) ─▶ dist/
            applies owl.fileset.txt                      one page per file, two views
```

- **`filter/`** — `owl-filter`, a Rust CLI that applies an `owl.fileset.txt`
  manifest and copies the *included* files into an output directory. This is a
  Nix-level **pre-filter**: excluded paths (notably `secrets/`) never reach the
  renderer. See the top of `owl.fileset.txt` (at the checkout root) for the
  manifest format — globs parsed by the `globset` crate, `!` negation, `@import`.
- **`web/`** — `owl-web`, an Astro app that renders whatever tree it is handed via
  `$OWL_INPUT_DIR`. It does no filtering. Highlighting and comment detection use
  Shiki (already in Astro's closure); the comment-detection engine lives behind
  one function (`src/lib/highlight.ts` → `classifyCommentLines`) so tree-sitter
  can replace it later without a rewrite.

## Dev loop

`owl-filter` and `node` come from the dev shell (`nix develop`).

```bash
# 1. produce a pre-filtered tree from a checkout
owl-filter --fileset ../../owl.fileset.txt ../.. /tmp/owl-out

# 2. render it
cd web
OWL_INPUT_DIR=/tmp/owl-out npm install   # first time
OWL_INPUT_DIR=/tmp/owl-out npm run build  # gen-manifest + astro build -> web/dist
npx serve dist                            # browse http://localhost:3000
```

`npm run dev` (with `OWL_INPUT_DIR` set) gives the live Astro dev server.

## Build (Nix)

```bash
nix build .#site                # the whole monorepo as a static site -> result/
nix build .#owl-filter          # just the Rust filter binary -> result/bin/owl-filter
nix run  .#owl-filter -- --fileset <fileset> <src> <out>
nix flake check                 # clippy(-Dwarnings) + fmt + audit + nextest
```

`.#site` renders the `everything` input **at the commit `flake.lock` pins it to**
— a `git+file` input, so `.gitignore` is respected and no `--impure` is needed —
*not* your current working tree. To build a specific commit or checkout:

```bash
nix flake update everything          # re-pin to the input repo's HEAD, then build
# ...or point at any checkout without touching the lock (e.g. a local working copy):
nix build .#site --override-input everything git+file:///path/to/checkout
```

Gotcha: the lock pins `everything` to `/Users/yuto/src/everything`, so until an
owl commit lands there and you re-lock, plain `nix build .#site` renders a tree
without owl — and *errors* if that tree has no `owl.fileset.txt` for the filter to
load. Until then, use `--override-input` pointing at the checkout that holds your
work. Deploy `result/` to any static host.

Lower-level pieces are also exposed for consumers wiring their own inputs:
`packages.owl-filter` and the functions `lib.{filterTree,renderTree,renderCheckout}`.
Regenerate `npmDepsHash` on `web/package-lock.json` changes:
`nix run nixpkgs#prefetch-npm-deps -- web/package-lock.json`.

## Notes & limitations (v1)

- Comment detection is Shiki-scope based: it coalesces consecutive whole-line
  comments (and block comments) into one box; trailing inline comments stay in the
  code. Unknown/ungrammared file types fall back to plain highlight with no boxes.
- The sidebar tree is inlined into every page; fine at this repo's scale, revisit
  for very large checkouts.
- Deferred to later: tree-sitter + symbol cross-refs / jump-to-definition, Pagefind
  search, git blame/history, request-sending functions.
- `Cargo.lock` and `flake.lock` must be committed (crane needs the lock for
  reproducible builds).
