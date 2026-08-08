// Build-time codegen (runs before `astro build`, mirroring channel-party's
// gen-registry.mjs). Reads the PRE-FILTERED checkout at $OWL_INPUT_DIR, copies
// every file into .owl-tree/ (a sibling of src/, NOT under it — the bodies are
// read via fs at build time, never imported, so keeping them out of srcDir stops
// Astro's dep scanner from crawling them and failing on their imports), and writes
// src/generated/manifest.json — the file list the dynamic routes enumerate.
// owl-web does no filtering itself; whatever is under OWL_INPUT_DIR is rendered.
import { mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const webDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const genDir = join(webDir, 'src', 'generated');
const treeDir = join(webDir, '.owl-tree');

const input = process.env.OWL_INPUT_DIR;
if (!input) {
  console.error('gen-manifest: OWL_INPUT_DIR is not set.');
  console.error('  owl-web renders a pre-filtered tree; produce one with owl-filter first:');
  console.error('    owl-filter --fileset owl.fileset.txt <checkout> /tmp/owl-out');
  console.error('    OWL_INPUT_DIR=/tmp/owl-out npm run build');
  process.exit(1);
}
const root = resolve(input);

// A file is treated as binary (shown as a notice, not rendered) if it has a NUL
// byte in its first 8 KB.
function isBinary(buf) {
  const n = Math.min(buf.length, 8000);
  for (let i = 0; i < n; i++) if (buf[i] === 0) return true;
  return false;
}

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
      files.push({ path: rel, size: buf.length, binary: isBinary(buf) });
    }
    // symlinks (neither isDirectory nor isFile) are skipped.
  }
}

await rm(treeDir, { recursive: true, force: true });
await mkdir(treeDir, { recursive: true });
await walk(root);
files.sort((a, b) => a.path.localeCompare(b.path));
await mkdir(genDir, { recursive: true });
await writeFile(join(genDir, 'manifest.json'), JSON.stringify({ files }));
console.log(`gen-manifest: ${files.length} files from ${root}`);
