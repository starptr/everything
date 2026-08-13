# fileset

Filter files from a directory with a gitignore-like manifest. Given a **fileset
manifest** and a source directory, `fileset` copies the *included* files into an
output directory, preserving relative structure — a general-purpose pre-filter, so
excluded paths (e.g. `secrets/`) never reach whatever consumes the pruned tree.

Everything under the source is included by default; the manifest's rules subtract from
that set (and `!` can add back). It is **not** a `.gitignore`: it never touches git
tracking, only what gets copied.

## CLI

```bash
fileset --fileset <manifest> <src> <out>
```

Copies every file under `<src>` that `<manifest>` includes into `<out>`. Symlinks are
skipped and `.git`/`.jj` are pruned before descent. Prints a copied-file count to
stderr.

As a standalone Nix flake (invoked by path):

```bash
nix run  ./experimental/fileset -- --fileset ./owl.fileset.txt . /tmp/out
nix build ./experimental/fileset   # -> result/bin/fileset
nix flake check ./experimental/fileset
```

## Library

The crate also exposes a small library (`fileset`):

```rust
use fileset::{Fileset, filter_tree};

let manifest = Fileset::load(Path::new("owl.fileset.txt"))?;
let included = manifest.includes(Path::new("src/main.rs")); // -> bool
let n = filter_tree(Path::new("."), Path::new("/tmp/out"), &manifest)?; // walk + copy
```

- `Fileset::load(&Path)` — parse a manifest, inlining `@import`s.
- `Fileset::includes(&Path)` — whether a tree-root-relative path is included.
- `filter_tree(src, out, &Fileset)` — copy every included file under `src` into `out`,
  returning the count.

## Manifest format (gitignore-like)

```
#                Line comment. Blank lines are ignored.
<glob>           Exclude paths matching this glob.
!<glob>          Re-include paths matching this glob (negation).
@import <path>   Inline another fileset / .gitignore-style file, with <path>
                 resolved relative to THIS file's directory.
```

Later rules win, and `@import` inlines its rules at that position — so ordering and
negation across an import boundary are well-defined. Imported `.gitignore` files are
read under these same rules (a best-effort superset of gitignore syntax).

### Matching

Each glob is compiled by the [`globset`](https://docs.rs/globset) crate with
`literal_separator(true)`, anchored gitignore-style:

- `*` `?` — match within a single path segment (never across `/`)
- `**` — spans path segments
- `{a,b}` `[0-9]` — alternation / character classes

A pattern containing a `/` (e.g. `vendor/lib/`) is **anchored to the tree root**; a
pattern with no `/` (e.g. `*.lock`, `node_modules/`) matches **at any depth**. A
trailing `/` matches a directory and everything under it. Paths are matched relative to
the source root.

### Ordering

Since the last matching rule wins, list subtree exclusions **last** — after every `!`
negation — so a negation can never re-include a file that lives inside an excluded tree
(this is what keeps something like `secrets/` absolute).
