// Single markdown-it instance, used both for whole `.md` files and for the prose
// bodies lifted out of comments. `html: false` escapes raw HTML in the source
// (safe default for a browsable site); links are auto-detected.

import MarkdownIt from 'markdown-it';

const md = new MarkdownIt({ html: false, linkify: true, typographer: false });

export function renderMarkdown(text: string): string {
  return md.render(text);
}
