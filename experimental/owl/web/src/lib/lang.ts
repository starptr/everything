// The single source of truth for how a file is rendered. `renderPlan` deduces a
// file's `kind` from its manifest entry; the renderer (render.ts) chooses its
// logic from that kind alone — nothing downstream re-derives "is this markdown?"
// or "is this binary?". `langForPath` (extension → Shiki grammar) is the
// primitive `renderPlan` is built on; an unknown extension has no grammar and
// becomes the `plain` kind (plain text, no highlighting, no comment boxes).

import type { FileEntry } from './manifest';

const EXT_TO_LANG: Record<string, string> = {
  nix: 'nix',
  rs: 'rust',
  py: 'python',
  sh: 'bash',
  bash: 'bash',
  zsh: 'bash',
  fish: 'fish',
  yaml: 'yaml',
  yml: 'yaml',
  json: 'json',
  jsonc: 'jsonc',
  json5: 'json5',
  jsonnet: 'jsonnet',
  libsonnet: 'jsonnet',
  toml: 'toml',
  ts: 'typescript',
  tsx: 'tsx',
  mts: 'typescript',
  cts: 'typescript',
  js: 'javascript',
  mjs: 'javascript',
  cjs: 'javascript',
  jsx: 'jsx',
  html: 'html',
  css: 'css',
  scss: 'scss',
  sql: 'sql',
  md: 'markdown',
  markdown: 'markdown',
  astro: 'astro',
  vue: 'vue',
  svg: 'xml',
  xml: 'xml',
};

/** Shiki language id for a path, or undefined when the extension is unknown. */
export function langForPath(path: string): string | undefined {
  const base = path.split('/').pop() ?? '';
  const dot = base.lastIndexOf('.');
  if (dot <= 0) return undefined; // no extension (or dotfile like `.envrc`)
  return EXT_TO_LANG[base.slice(dot + 1).toLowerCase()];
}

// How a file is rendered. `markdown` → full prose; `code` → highlighted source
// with comment runs lifted into boxes; `plain` → escaped text, no grammar;
// `binary` → a "not rendered" notice. Only `markdown`/`code` carry a grammar.
export type RenderKind = 'binary' | 'markdown' | 'code' | 'plain';

export interface RenderPlan {
  kind: RenderKind;
  /** Shiki grammar id for `markdown`/`code`; undefined for `binary`/`plain`. */
  lang?: string;
}

/** Deduce how a file should be rendered, from its manifest entry alone. */
export function renderPlan(entry: FileEntry): RenderPlan {
  if (entry.binary) return { kind: 'binary' };
  const lang = langForPath(entry.path);
  if (lang === undefined) return { kind: 'plain' };
  if (lang === 'markdown') return { kind: 'markdown', lang };
  return { kind: 'code', lang };
}
