// Build-time codegen (runs before `astro build`, mirroring channel-party's
// gen-registry.mjs). Reads the PRE-FILTERED checkout at OWL_INPUT_DIR, copies
// every file into .owl-tree/ (a sibling of src/, NOT under it — the bodies are
// read via fs at build time, never imported, so keeping them out of srcDir stops
// Astro's dep scanner from crawling them and failing on their imports), and writes
// src/generated/manifest.json — the file list the dynamic routes enumerate.
// owl-web does no filtering itself; whatever is under OWL_INPUT_DIR is rendered.
//
// The manifest generator is exported as genManifest({ inputDir, title, webDir }) so
// owl-render.mjs can drive it against a writable work dir; running this file directly
// is the `npm run gen:manifest` CLI (reads OWL_INPUT_DIR / OWL_TITLE, targets web/).
import { mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// A file is treated as binary (shown as a notice, not rendered) if it has a NUL
// byte in its first 8 KB.
function isBinary(buf) {
  const n = Math.min(buf.length, 8000);
  for (let i = 0; i < n; i++) if (buf[i] === 0) return true;
  return false;
}

// 64-bit hex digest — short enough to keep the manifest small, wide enough that a
// collision across a checkout is not a practical concern. Used for cacheKeys.
const shortHash = (data) => createHash('sha256').update(data).digest('hex').slice(0, 16);

// Generate .owl-tree/ + src/generated/manifest.json under `webDir` from the tree at
// `inputDir`. Pure of process.cwd(): every output path is derived from `webDir`.
// Returns the manifest object.
export async function genManifest({ inputDir, title = null, webDir }) {
  const genDir = join(webDir, 'src', 'generated');
  const treeDir = join(webDir, '.owl-tree');
  const root = resolve(inputDir);

  const files = [];
  async function walk(absDir) {
    const dirents = await readdir(absDir, { withFileTypes: true });
    for (const d of dirents.sort((a, b) => a.name.localeCompare(b.name))) {
      if (d.isDirectory()) {
        if (d.name === '.git' || d.name === '.jj') continue; // defensive; usually pre-filtered
        await walk(join(absDir, d.name));
      } else if (d.isFile()) {
        const abs = join(absDir, d.name);
        const rel = relative(root, abs).split(sep).join('/');
        const buf = await readFile(abs);
        const dest = join(treeDir, rel);
        await mkdir(dirname(dest), { recursive: true });
        await writeFile(dest, buf);
        files.push({ path: rel, size: buf.length, binary: isBinary(buf), hash: shortHash(buf) });
      }
      // symlinks (neither isDirectory nor isFile) are skipped.
    }
  }

  await rm(treeDir, { recursive: true, force: true });
  await mkdir(treeDir, { recursive: true });
  await walk(root);
  files.sort((a, b) => a.path.localeCompare(b.path));

  // navHash keys the file-tree STRUCTURE (paths only) that the sidebar inlines into
  // every page. It changes on add/rename/delete but NOT on a content edit, so a page
  // whose own body is unchanged keeps its cached output when another file is edited —
  // the lever that makes incremental builds skip untouched pages.
  const navHash = shortHash(files.map((f) => f.path).join('\n'));

  const manifest = { title: title?.trim() || null, navHash, files };
  await mkdir(genDir, { recursive: true });
  await writeFile(join(genDir, 'manifest.json'), JSON.stringify(manifest));
  return manifest;
}

// CLI entry: `OWL_INPUT_DIR=… OWL_TITLE=… node scripts/gen-manifest.mjs` (targets web/).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const inputDir = process.env.OWL_INPUT_DIR;
  if (!inputDir) {
    console.error('gen-manifest: OWL_INPUT_DIR is not set.');
    console.error('  owl-web renders a pre-filtered tree; produce one with owl-filter first:');
    console.error('    owl-filter --fileset owl.fileset.txt <checkout> /tmp/owl-out');
    console.error('    OWL_INPUT_DIR=/tmp/owl-out npm run build');
    process.exit(1);
  }
  const webDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const title = process.env.OWL_TITLE;
  const { files } = await genManifest({ inputDir, title, webDir });
  console.log(`gen-manifest: ${files.length} files from ${resolve(inputDir)}${title?.trim() ? ` (title: ${title.trim()})` : ''}`);
}
