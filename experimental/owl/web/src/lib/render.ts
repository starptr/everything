// Produces the HTML for a file's two views. Both branch on the file's render
// `kind` (deduced once by `renderPlan` in lang.ts — the single source of truth)
// and highlight source with Shiki. `raw` is the whole file in one pass; `rendered`
// lifts comment runs into markdown boxes and fully renders `.md`, but the
// surrounding source is cut from the same single whole-file pass (so grammar
// context and colors survive) and numbered by its real file lines.

import { extractSegments, stripMarkers } from './comments';
import { highlightLines, highlightToHtml } from './highlight';
import { renderPlan } from './lang';
import { readTreeFile, type FileEntry } from './manifest';
import { renderMarkdown } from './markdown';

function binaryNotice(entry: FileEntry): string {
  return `<div class="owl-binary">Binary file — ${entry.size.toLocaleString()} bytes, not rendered.</div>`;
}

export async function renderRawHtml(entry: FileEntry): Promise<string> {
  const plan = renderPlan(entry);
  if (plan.kind === 'binary') return binaryNotice(entry);
  return highlightToHtml(readTreeFile(entry.path), plan.lang, 1);
}

export async function renderRenderedHtml(entry: FileEntry): Promise<string> {
  const plan = renderPlan(entry);
  if (plan.kind === 'binary') return binaryNotice(entry);
  const src = readTreeFile(entry.path);
  if (plan.kind === 'markdown') {
    return `<div class="owl-prose">${renderMarkdown(src)}</div>`;
  }
  // No grammar to find comments in — render the whole file as source, identical
  // to the raw view.
  if (plan.kind === 'plain') {
    return highlightToHtml(src, undefined, 1);
  }
  // kind === 'code': interleave prose boxes (comment runs) with highlighted code.
  // The file is tokenized ONCE (highlightLines) so grammar context survives; each
  // code run is a slice of that single pass, still colored and numbered by its
  // real file lines.
  const hl = await highlightLines(src, plan.lang);
  const segments = await extractSegments(src, plan.lang);
  const parts: string[] = [];
  for (const seg of segments) {
    if (seg.kind === 'prose') {
      const prose = stripMarkers(seg.text);
      if (prose !== '') parts.push(`<div class="owl-comment">${renderMarkdown(prose)}</div>`);
    } else {
      const start = seg.startLine - 1;
      parts.push(hl.block(start, start + seg.text.split('\n').length));
    }
  }
  return parts.join('\n');
}
