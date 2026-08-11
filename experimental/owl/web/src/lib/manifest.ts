// Loads src/generated/manifest.json (written by scripts/gen-manifest.mjs) and
// derives the file/dir structure the pages need. Also reads raw file bodies from
// the .owl-tree/ directory at build time.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export interface FileEntry {
  path: string;
  size: number;
  binary: boolean;
  /** 64-bit content hash (gen-manifest); the per-file half of a page's cacheKey. */
  hash: string;
}

interface Manifest {
  title?: string | null;
  navHash?: string;
  files: FileEntry[];
}

// Read the generated manifest via fs, NOT a static `import`: importing the JSON would
// put it in every page's module dependency graph, so any content edit (which rewrites
// the manifest) would bust incrementalBuild's whole per-page cache. An fs read keeps it
// out of the graph — per-page data changes flow through cacheKeys instead. cwd is the
// project root during `astro build` (owl-render chdir's there), same as treeDir below.
const manifest = JSON.parse(
  readFileSync(join(process.cwd(), 'src', 'generated', 'manifest.json'), 'utf8'),
) as Manifest;

export const files: FileEntry[] = manifest.files;

/** Hash of the file-tree structure (paths only) inlined into every page's sidebar;
 *  the shared half of every page's cacheKey (see gen-manifest.mjs). */
export const navHash: string = manifest.navHash ?? '';

/** Site title shown in the shell (breadcrumb root, sidebar logo, browser tab).
 *  Set via the `OWL_TITLE` build env (owl's `title` Nix parameter); defaults to
 *  owl's own name. */
export const siteTitle: string = manifest.title ?? 'owl';

// gen-manifest.mjs writes the file bodies under .owl-tree/ (outside src/, so
// Astro's dep scanner ignores them); astro build runs with cwd at the project
// root (the bundled module's location is not stable).
const treeDir = join(process.cwd(), '.owl-tree');

/** Read a file's raw text from the generated tree (build time only). */
export function readTreeFile(rel: string): string {
  return readFileSync(join(treeDir, rel), 'utf8');
}

export function fileByPath(path: string): FileEntry | undefined {
  return files.find((f) => f.path === path);
}

/** Every directory path in the tree (excluding the root ""), sorted. */
export function allDirs(): string[] {
  const set = new Set<string>();
  for (const f of files) {
    const parts = f.path.split('/');
    for (let i = 1; i < parts.length; i++) set.add(parts.slice(0, i).join('/'));
  }
  return [...set].sort();
}

/** Immediate subdirectories and files of a directory ("" is the root). */
export function childrenOf(dir: string): { dirs: string[]; files: FileEntry[] } {
  const prefix = dir === '' ? '' : `${dir}/`;
  const subdirs = new Set<string>();
  const childFiles: FileEntry[] = [];
  for (const f of files) {
    if (!f.path.startsWith(prefix)) continue;
    const rest = f.path.slice(prefix.length);
    const parts = rest.split('/');
    if (parts.length === 1) childFiles.push(f);
    else subdirs.add(prefix + parts[0]);
  }
  return {
    dirs: [...subdirs].sort(),
    files: childFiles.sort((a, b) => a.path.localeCompare(b.path)),
  };
}

/** Content hash of the README.md a tree page would inline for `dir` (mirrors
 *  DirListing's selection), or '' if none. The per-directory half of a tree page's
 *  cacheKey, so a README edit re-renders the directory page that renders it. */
export function dirReadmeHash(dir: string): string {
  const readme = childrenOf(dir).files.find(
    (f) => f.path.toLowerCase().endsWith('readme.md') && !f.binary,
  );
  return readme?.hash ?? '';
}

export interface TreeNode {
  name: string;
  path: string;
  isDir: boolean;
  children: TreeNode[];
}

/** Build the full nested tree (dirs before files, each sorted by name). */
export function buildTree(): TreeNode {
  const root: TreeNode = { name: '', path: '', isDir: true, children: [] };
  for (const f of files) {
    const parts = f.path.split('/');
    let node = root;
    for (let i = 0; i < parts.length; i++) {
      const name = parts[i];
      const isDir = i < parts.length - 1;
      const path = parts.slice(0, i + 1).join('/');
      let child = node.children.find((c) => c.name === name && c.isDir === isDir);
      if (!child) {
        child = { name, path, isDir, children: [] };
        node.children.push(child);
      }
      node = child;
    }
  }
  const sort = (n: TreeNode): void => {
    n.children.sort((a, b) =>
      a.isDir === b.isDir ? a.name.localeCompare(b.name) : a.isDir ? -1 : 1,
    );
    n.children.forEach(sort);
  };
  sort(root);
  return root;
}
