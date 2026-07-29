// libghostty adapter — Ghostty's VT engine in the browser via the ghostty-web WASM build.
// `createGhosttyBackend` is the only place that awaits init() (loads the WASM, which
// ghostty-web embeds as an inline data: URL — no separate asset to resolve). ghostty-web
// ships an xterm-shaped Terminal + its own FitAddon, so this mirrors xtermBackend closely.
//
// Two option gaps vs xterm: no lineHeight, and no fontWeight/letterSpacing/allowProposedApi.
// We pass only what ghostty-web understands. Because it has no line-height (and to stay
// safe about runtime option mutation), setTheme/setLineHeight return false — Terminal.tsx
// then remounts the pane at the new settings via its remount token.

import { init, Terminal as GhosttyTerm, FitAddon, type ITheme } from "ghostty-web";
import type { BackendOptions, TerminalBackend, TerminalSize } from "./backend";

class GhosttyBackend implements TerminalBackend {
  readonly id = "ghostty" as const;
  private term: GhosttyTerm;
  private fitAddon = new FitAddon();

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
  }

  write(data: string) {
    this.term.write(data);
  }

  onData(cb: (data: string) => void) {
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
  return new GhosttyBackend(o);
}
