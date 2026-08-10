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

## Build / run

Commands run from `experimental/owl/`. `owl-filter` always walks the on-disk
checkout and applies `owl.fileset.txt`; `owl-web` renders whatever tree it's
handed via `$OWL_INPUT_DIR`.

`owl-web`'s build (`gen-manifest` + `astro build`) reads two environment variables:

- `OWL_INPUT_DIR` (required) — the pre-filtered tree to render (produce one with
  `owl-filter`).
- `OWL_TITLE` (optional, default `owl`) — the site title shown in the shell
  (breadcrumb root, sidebar logo, browser-tab suffix). The Nix build sets it from
  the `title` parameter (§4); `.#site` uses `everything`.

### 1. Development — `owl-filter` + `npm run dev`

The fast inner loop: a hermetic pre-filter feeding Astro's live dev server (HMR).
`npm` needs `node` (e.g. `nix develop`, or `nix shell nixpkgs#nodejs`).

```bash
# pre-filter a checkout (or any tree) into a pruned dir
nix run .#owl-filter -- --fileset ../../owl.fileset.txt ../.. /tmp/owl-out
# live server with hot reload — re-run the filter when browsed files change
cd web && OWL_INPUT_DIR=/tmp/owl-out OWL_TITLE=everything npm run dev   # http://localhost:4321
```

**Scripts** (run from the repo root, no arguments) that wrap this whole loop:
`run-owl-for-owl-development-with-frozen-fileset.sh` does the filter-once + `npm run
dev` above — renderer hot-reloads, content frozen — the everyday choice for hacking
on owl; `run-owl-for-owl-development-with-dynamic-fileset.sh` adds a watcher that
re-filters on every repo change, so new/changed/deleted files show up live.

Iterating on the filter itself? `cargo run --manifest-path filter/Cargo.toml --`
rebuilds faster than `nix run`.

> **Do not use `npm run build`.** It is a non-hermetic, non-development static
> build (local `node`/npm, no fileset pre-filter, no reproducibility) with no use
> case here: for development use `npm run dev`; for a real static site use the
> hermetic Nix build below.

### 2. Hermetic static site — `nix build .#site`

Renders a checkout to deployable static HTML in `result/`, reproducibly.

```bash
nix build .#site        # renders the `everything` input at the commit flake.lock pins
```

`.#site` renders the **committed** tree of the `everything` input (a `git+file`
input, so `.gitignore` is respected and no `--impure` is needed) — *not* your
working tree. To target a different commit or checkout:

```bash
# a) any checkout, without touching the lock:
nix build .#site --override-input everything git+file:///path/to/checkout
# b) re-pin `everything` to the input repo's HEAD, then build:
nix flake update everything && nix build .#site
```

Gotcha: the lock pins `everything` to `/Users/yuto/src/everything`; until an owl
commit lands there and you re-lock, plain `nix build .#site` renders a tree
*without* owl — and errors if it has no `owl.fileset.txt`. Use (a) until then.
Deploy `result/` to any static host.

**Script** (repo root, no arguments): `run-owl-for-general-development.sh` is this
option applied to your **live working tree** — it filters the on-disk checkout (so
new files appear and deleted ones vanish, no `git add` or commit), runs the hermetic
`nix build .#site` above, and serves the result. Use it to browse a feature in
progress; see the script header for details.

### 3. Filter binary only — `nix build .#owl-filter`

```bash
nix build .#owl-filter                                   # -> result/bin/owl-filter
nix run  .#owl-filter -- --fileset <fileset> <src> <out> # also apps.default
```

**Scripts:** none wrap this standalone, though all three scripts call
`nix run .#owl-filter` internally to prune the tree they render.

### 4. As a library in another flake

For a consumer flake that has a checkout as a store path and wants the finished
site, bypassing owl's own `everything` input:

```nix
# `title` is optional (default "owl") — the site name shown in owl's UI.
owl.lib.${system}.renderCheckout { src = ./some-checkout; title = "my-repo"; } # filter + render
owl.lib.${system}.renderTree { tree = pruned-store-path; title = "my-repo"; }  # render a pre-filtered tree
owl.lib.${system}.filterTree { src = ...; fileset = ...; }                     # just the pre-filter
owl.packages.${system}.owl-filter                                             # the filter binary
```

**Scripts:** none — this path is for other flakes consuming owl, not local dev.

Regenerate `npmDepsHash` on `web/package-lock.json` changes:
`nix run nixpkgs#prefetch-npm-deps -- web/package-lock.json`. `Cargo.lock` and
`flake.lock` must stay committed (crane needs the lock for reproducible builds).

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
