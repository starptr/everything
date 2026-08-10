// Shiki-based highlighting plus the v1 comment classifier. Uses Shiki's shorthand
// API (full language bundle, lazy-loaded); an unknown grammar renders via Shiki's
// built-in `plaintext`, so highlighted and plain code share one DOM
// (`<pre class="shiki">` with `.line` spans) and one CSS class. Highlighting runs
// at build time only — nothing ships to the client but HTML + CSS. Dual light/dark
// themes are emitted as CSS variables and swapped by prefers-color-scheme (see
// Shell.astro).

import { codeToHast, codeToTokens, hastToHtml } from 'shiki';
import type { ShikiTransformer, ThemedToken } from 'shiki';
import type { Element, ElementContent, Root } from 'hast';

const THEMES = { light: 'github-light', dark: 'github-dark' } as const;

// Shiki's no-op grammar: line-wrapped, untokenized. Used for unknown extensions
// and as the fallback when a named grammar fails to load.
const PLAIN = 'plaintext';

// Stamps each line with its file-absolute number as `id="L{n}"` (for #L
// permalinks) and `data-line-no` (rendered as the gutter in both views). `line`
// is 1-based within the highlighted chunk; `startLine` is that chunk's first line
// in the file, so a rendered-view code block after a comment run numbers correctly.
function lineNumbers(startLine: number): ShikiTransformer {
  return {
    name: 'owl-line-numbers',
    line(node, line) {
      const n = startLine + line - 1;
      node.properties.id = `L${n}`;
      node.properties['data-line-no'] = String(n);
    },
  };
}

// Tokenize a chunk once to a hast tree (dual themes as CSS vars + gutter). An
// unknown or unavailable grammar degrades to `plaintext` — identical markup, no
// token colors — so every code block renders the same way.
async function toHast(
  code: string,
  lang: string | undefined,
  startLine: number,
): Promise<Root> {
  const opts = {
    themes: THEMES,
    defaultColor: false,
    transformers: [lineNumbers(startLine)],
  } as const;
  try {
    return await codeToHast(code, { lang: lang ?? PLAIN, ...opts });
  } catch {
    return await codeToHast(code, { lang: PLAIN, ...opts });
  }
}

/**
 * Highlight a whole chunk to dual-theme HTML with a line-number gutter, numbered
 * from `startLine`. Used by the raw and plain views (the entire file in one pass).
 */
export async function highlightToHtml(
  code: string,
  lang: string | undefined,
  startLine = 1,
): Promise<string> {
  return hastToHtml(await toHast(code, lang, startLine));
}

/** A file tokenized once, exposing contiguous line ranges as separate blocks. */
export interface HighlightedLines {
  /** Number of source lines (1:1 with `code.split('\n')`). */
  count: number;
  /** Render source lines `[start, end)` (0-based) as one `<pre class="shiki">`. */
  block(start: number, end: number): string;
}

/**
 * Tokenize a file ONCE, then hand back its highlighted lines to be sliced into
 * blocks. The rendered view of a `code` file interleaves prose boxes with source;
 * re-tokenizing each source run in isolation would lose stateful grammar context
 * (Astro's `---` frontmatter fence, template literals, multi-line comments), so
 * every block is cut from this single whole-file pass and stays correctly colored.
 */
export async function highlightLines(
  code: string,
  lang: string | undefined,
): Promise<HighlightedLines> {
  const root = await toHast(code, lang, 1);
  const pre = root.children.find((c): c is Element => c.type === 'element') as Element;
  const codeEl = pre.children.find((c): c is Element => c.type === 'element') as Element;
  const lineEls = codeEl.children.filter((c): c is Element => c.type === 'element');
  return {
    count: lineEls.length,
    block(start, end) {
      const kids: ElementContent[] = [];
      for (let k = start; k < end; k++) {
        if (k > start) kids.push({ type: 'text', value: '\n' });
        kids.push(lineEls[k]);
      }
      const codeNode: Element = { type: 'element', tagName: 'code', properties: {}, children: kids };
      const preNode: Element = { ...pre, children: [codeNode] };
      return hastToHtml({ type: 'root', children: [preNode] });
    },
  };
}

// Per-line comment classification — the ONLY place the comment-detection engine
// lives. A line is a "comment line" when its non-whitespace tokens are all
// comment-scoped (a whole-line comment or a line inside a block comment); a line
// with any code token (including a trailing inline comment) is not. Swapping in
// web-tree-sitter later means replacing just this function. Unknown lang or a
// tokenization failure → every line false (all code, no boxes).
export async function classifyCommentLines(
  code: string,
  lang: string | undefined,
): Promise<boolean[]> {
  const lineCount = code.split('\n').length;
  if (!lang) return new Array<boolean>(lineCount).fill(false);
  try {
    const { tokens } = await codeToTokens(code, {
      lang,
      theme: 'github-light',
      includeExplanation: true,
    });
    const result = tokens.map((line) => {
      let sawCode = false;
      let sawComment = false;
      for (const t of line) {
        if (t.content.trim() === '') continue;
        if (isCommentToken(t)) sawComment = true;
        else sawCode = true;
      }
      return sawComment && !sawCode;
    });
    while (result.length < lineCount) result.push(false);
    return result.slice(0, lineCount);
  } catch {
    return new Array<boolean>(lineCount).fill(false);
  }
}

// A real comment scope follows the TextMate convention `comment.line.*` /
// `comment.block.*`. Astro tags its `---` frontmatter fence with a *bare*
// `comment` scope — a structural JS/HTML divider, not prose — so match the
// sub-scoped form to keep the fence as code instead of lifting it into a box.
function isCommentToken(token: ThemedToken): boolean {
  const ex = token.explanation;
  if (!ex || ex.length === 0) return false;
  return ex.every((e) => e.scopes.some((s) => s.scopeName.startsWith('comment.')));
}
