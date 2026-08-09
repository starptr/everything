// libghostty adapter — Ghostty's VT engine in the browser via the ghostty-web WASM build.
// `createGhosttyBackend` is the only place that awaits init() (loads the WASM, which
// ghostty-web embeds as an inline data: URL — no separate asset to resolve). ghostty-web
// ships an xterm-shaped Terminal + its own FitAddon, so this mirrors xtermBackend closely.
//
// Two option gaps vs xterm: no lineHeight, and no fontWeight/letterSpacing/allowProposedApi.
// We pass only what ghostty-web understands. Because it has no line-height (and to stay
// safe about runtime option mutation), setTheme/setLineHeight return false — Terminal.tsx
// then remounts the pane at the new settings via its remount token.
//
// Three shims paper over ghostty-web quirks that xterm handles natively: we answer the DA1
// query (see below), hide the input textarea's caret (see open()), and correct cell sizing —
// `createGhosttyBackend` waits for the webfont before the renderer first measures, and open()
// rounds the cell width to the nearest pixel instead of ghostty's ceil (which ran cells ~10%
// too wide). ghostty-web exposes no width knob, so both live here in the adapter.

import { init, Terminal as GhosttyTerm, FitAddon, type ITheme } from "ghostty-web";
import type { BackendOptions, TerminalBackend, TerminalSize } from "./backend";

// ghostty-web's readResponse() answers only DSR, not the Primary Device Attributes query
// (DA1, `ESC [ c` / `ESC [ 0 c`). A shell like fish blocks ~10s waiting for that reply
// before drawing its prompt, so we answer it ourselves with the standard VT100/AVO response.
const DA1_QUERY = /\x1b\[0?c/;
const DA1_RESPONSE = "\x1b[?1;2c";

class GhosttyBackend implements TerminalBackend {
  readonly id = "ghostty" as const;
  private term: GhosttyTerm;
  private fitAddon = new FitAddon();
  private emitData?: (data: string) => void;

  constructor(o: BackendOptions) {
    this.term = new GhosttyTerm({
      cursorBlink: o.cursorBlink,
      cursorStyle: o.cursorStyle,
      fontSize: o.fontSize,
      fontFamily: o.fontFamily,
      theme: o.theme as ITheme,
      scrollback: o.scrollback,
    });
    this.term.loadAddon(this.fitAddon);
  }

  open(container: HTMLElement) {
    this.term.open(container);
    // ghostty-web's input <textarea> lacks the hiding CSS xterm gives its helper textarea, so
    // its native caret shows as a stray blinking cursor near the pane's top-left. Ghostty draws
    // its own cursor on the canvas, so hide the textarea's caret (it stays focusable for input).
    const input = container.querySelector("textarea");
    if (input) input.style.caretColor = "transparent";
    this.roundCellWidth();
  }

  // ghostty-web sizes a cell at ceil(measureText("M").width) — always the next whole pixel up,
  // making cells ~1px (~10%) wider than the glyph advance. Round to the nearest pixel instead
  // (what native terminals do), so libghostty cells match xterm's width. renderer/measureFont
  // are ghostty-web internals (no public width knob exists), so this is a deliberate adapter
  // shim. Runs synchronously in open(), before Terminal.tsx's fit() and WS connect, so the
  // corrected metrics flow through the normal fit/resize path with no Terminal.tsx changes.
  private roundCellWidth() {
    const renderer = (this.term as unknown as { renderer?: Record<string, unknown> }).renderer;
    if (!renderer || typeof renderer.measureFont !== "function") return;
    const measureUpstream = (renderer.measureFont as () => Record<string, unknown>).bind(renderer);
    const ctx = document.createElement("canvas").getContext("2d");
    renderer.measureFont = () => {
      const m = measureUpstream(); // upstream height/baseline (+ its ceil'd width, discarded)
      if (!ctx) return m;
      ctx.font = `${renderer.fontSize}px ${renderer.fontFamily}`;
      return { ...m, width: Math.round(ctx.measureText("M").width) };
    };
    (renderer.remeasureFont as () => void)(); // recompute this.metrics with the rounded width
  }

  write(data: string) {
    this.term.write(data);
    // Answer DA1 on ghostty's behalf (xterm replies natively; this path is ghostty-only).
    if (this.emitData && DA1_QUERY.test(data)) this.emitData(DA1_RESPONSE);
  }

  onData(cb: (data: string) => void) {
    this.emitData = cb;
    this.term.onData(cb);
  }

  fit() {
    this.fitAddon.fit();
  }

  get size(): TerminalSize {
    return { cols: this.term.cols, rows: this.term.rows };
  }

  // No live mutation: both are folded into Terminal.tsx's remount token, which rebuilds the
  // pane with the new theme/line settings baked into the constructor.
  setTheme(): boolean {
    return false;
  }

  setLineHeight(): boolean {
    return false;
  }

  dispose() {
    this.term.dispose();
  }
}

export async function createGhosttyBackend(o: BackendOptions): Promise<TerminalBackend> {
  await init();
  // The terminal font is an async swap webfont (see index.html); ghostty measures the cell
  // exactly once at open() and never remeasures, so wait for fonts to settle first — otherwise
  // it can lock the fallback font's advance. Resolves even on a failed/offline load, so it
  // can't hang; guarded for non-DOM (test) envs.
  if (typeof document !== "undefined" && document.fonts?.ready) {
    await document.fonts.ready;
  }
  return new GhosttyBackend(o);
}
