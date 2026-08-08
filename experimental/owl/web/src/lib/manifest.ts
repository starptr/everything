// Loads src/generated/manifest.json (written by scripts/gen-manifest.mjs) and
// derives the file/dir structure the pages need. Also reads raw file bodies from
// the .owl-tree/ directory at build time.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import manifestJson from '../generated/manifest.json';

export interface FileEntry {
  path: string;
  size: number;
  binary: boolean;
}

interface Manifest {
  files: FileEntry[];
}

export const files: FileEntry[] = (manifestJson as Manifest).files;

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
