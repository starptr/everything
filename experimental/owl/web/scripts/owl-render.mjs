// owl-render — render a pre-filtered tree to a static site with Astro's programmatic
// build() API. The renderer half of owl as a runtime binary (symmetric with owl-filter):
// the tree is a runtime argument, not a baked build input.
//
//   owl-render <input-tree> <out-dist> [--incremental] [--title T]
//              [--work-dir D] [--cache-dir D]
//
// Default is a FULL build — this is what the hermetic Nix `renderTree` calls, so the
// offline artifact is always complete. --incremental turns on experimental.incrementalBuild
// and, together with a persistent --work-dir (whose cache survives between runs), re-renders
// only the pages whose cacheKey changed. Re-invoking with the same --work-dir on a changed
// tree is how run-owl-for-general-development.sh rebuilds live and cheaply — each run is a
// fresh process (so the manifest is never stale) that reuses the previous run's cache.
//
// Astro writes (.owl-tree/, src/generated/, dist, caches) and manifest.ts reads .owl-tree
// via process.cwd(), but this file usually runs from a read-only Nix store. So we
// materialize a writable work dir: node_modules is symlinked (read-only, big) while the
// small source is copied, and every cache is redirected out of node_modules.
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  symlinkSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { build } from 'astro';
import { genManifest } from './gen-manifest.mjs';

function fail(msg) {
  console.error(`owl-render: ${msg}`);
  console.error('usage: owl-render <input-tree> <out-dist> [--incremental] [--title T]');
  console.error('                  [--work-dir D] [--cache-dir D]');
  process.exit(2);
}

function parseArgs(argv) {
  const positional = [];
  const opts = { incremental: false, title: 'owl', workDir: null, cacheDir: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--incremental') opts.incremental = true;
    else if (a === '--title') opts.title = argv[++i];
    else if (a === '--work-dir') opts.workDir = argv[++i];
    else if (a === '--cache-dir') opts.cacheDir = argv[++i];
    else if (a.startsWith('--')) fail(`unknown flag: ${a}`);
    else positional.push(a);
  }
  if (positional.length !== 2) fail('expected <input-tree> <out-dist>');
  opts.inputDir = resolve(positional[0]);
  opts.outDist = resolve(positional[1]);
  return opts;
}

// The bundled web package (astro.config.mjs, src/, node_modules, …) sits one level up from
// this script. `astro` is imported relative to this file, so it resolves from the bundled
// node_modules regardless of cwd.
const webDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function materializeWorkDir(explicit) {
  let workDir = explicit ? resolve(explicit) : mkdtempSync(join(tmpdir(), 'owl-render-'));
  mkdirSync(workDir, { recursive: true });
  // Physical path (resolve /tmp -> /private/tmp on macOS): Vite realpaths module ids, so
  // a symlinked component in `root`/cwd makes Astro join mismatched paths and the build
  // fails ("No cached compile metadata"). Same reason the run scripts use `pwd -P`.
  workDir = realpathSync(workDir);
  // node_modules: symlink (read-only is fine once caches are redirected — see main()).
  const nm = join(workDir, 'node_modules');
  if (!existsSync(nm)) symlinkSync(join(webDir, 'node_modules'), nm);
  // source: copy each item once (skip if already present, so a reused --work-dir isn't
  // re-copied — cpSync from the read-only store would EACCES on the existing tree). gen-
  // manifest writes src/generated + .owl-tree here; Astro writes .astro/ into the root.
  for (const item of ['astro.config.mjs', 'package.json', 'tsconfig.json', 'src', 'public']) {
    const from = join(webDir, item);
    const to = join(workDir, item);
    if (existsSync(from) && !existsSync(to)) cpSync(from, to, { recursive: true });
  }
  return workDir;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const ephemeral = !opts.workDir;
  const workDir = materializeWorkDir(opts.workDir);
  const cacheDir = opts.cacheDir ? resolve(opts.cacheDir) : join(workDir, '.cache', 'astro');
  const viteCacheDir = join(workDir, '.cache', 'vite');
  if (ephemeral) process.on('exit', () => rmSync(workDir, { recursive: true, force: true }));
  process.chdir(workDir); // manifest.ts resolves .owl-tree from process.cwd()

  await genManifest({ inputDir: opts.inputDir, title: opts.title, webDir: workDir });
  // Empty the output first so a deleted source file's page can't linger; incremental
  // still copies unchanged pages from the persistent cacheDir, not from dist.
  rmSync(opts.outDist, { recursive: true, force: true });
  await build({
    root: workDir,
    outDir: opts.outDist,
    cacheDir,
    vite: { cacheDir: viteCacheDir },
    logLevel: 'info',
    // Only set the experimental flag when actually building incrementally, so an offline
    // full build stays clean (and works on Astro versions without the flag).
    ...(opts.incremental ? { experimental: { incrementalBuild: true } } : {}),
  });
  console.log(`owl-render: ${opts.incremental ? 'incremental ' : ''}site -> ${opts.outDist}`);
}

main().catch((err) => {
  console.error(`owl-render: ${err?.stack ?? err}`);
  process.exit(1);
});
