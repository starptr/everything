// Turns a source file into ordered code/prose segments for the rendered view:
// runs of comment lines become `prose` (rendered as markdown boxes), everything
// else stays `code`. This sits on top of the classifier in highlight.ts — the
// engine-agnostic seam where tree-sitter can replace Shiki later.

import { classifyCommentLines } from './highlight';

export interface Segment {
  kind: 'code' | 'prose';
  text: string;
  // 1-based, file-absolute line of this segment's first line — lets the renderer
  // number a code block by its real position after earlier comment runs.
  startLine: number;
}

export async function extractSegments(
  code: string,
  lang: string | undefined,
): Promise<Segment[]> {
  const lines = code.split('\n');
  const isComment = await classifyCommentLines(code, lang);
  const segments: Segment[] = [];
  let i = 0;
  while (i < lines.length) {
    const comment = isComment[i] === true;
    let j = i;
    while (j < lines.length && (isComment[j] === true) === comment) j++;
    const text = lines.slice(i, j).join('\n');
    // Drop all-whitespace code runs so a blank line between two comment blocks
    // doesn't render as an empty code block (it just separates the two boxes).
    if (comment) segments.push({ kind: 'prose', text, startLine: i + 1 });
    else if (text.trim() !== '') segments.push({ kind: 'code', text, startLine: i + 1 });
    i = j;
  }
  return segments;
}

// Strip a single leading comment marker (and block-comment fences) per line,
// leaving prose for markdown. Only one marker is removed, so markdown that itself
// uses `#` (headings) inside a `#`-commented language survives.
export function stripMarkers(text: string): string {
  return text
    .split('\n')
    .map((line) => {
      let s = line.trim();
      if (s.startsWith('/*')) s = s.slice(2).trimStart();
      if (s.endsWith('*/')) s = s.slice(0, -2).trimEnd();
      return s.replace(/^(\/\/\/|\/\/!|\/\/|#|--|;|%|\*)\s?/, '');
    })
    .join('\n')
    .trim();
}
