// xterm.js adapter — the default backend. Wraps everything Terminal.tsx used to do inline:
// the XTerm instance, FitAddon, WebLinksAddon, and the xterm CSS. `setTheme`/`setLineHeight`
// mutate `term.options.*` live and return true, preserving the teardown-free re-theme /
// re-spacing (scrollback + WebSocket stay intact).

import { Terminal as XTerm, type ITheme, type FontWeight } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";
import type { BackendOptions, TerminalBackend, TerminalSize } from "./backend";
import { terminalTheme } from "./palette";
import type { ThemeName } from "../theme";

class XtermBackend implements TerminalBackend {
  readonly id = "xterm" as const;
  private term: XTerm;
  private fitAddon = new FitAddon();

  constructor(o: BackendOptions) {
    this.term = new XTerm({
      cursorBlink: o.cursorBlink,
      cursorStyle: o.cursorStyle,
      fontSize: o.fontSize,
      fontFamily: o.fontFamily,
      fontWeight: o.fontWeight as FontWeight,
      lineHeight: o.lineHeight,
      letterSpacing: o.letterSpacing,
      theme: o.theme as ITheme,
      allowProposedApi: o.allowProposedApi,
      scrollback: o.scrollback,
    });
    this.term.loadAddon(this.fitAddon);
    this.term.loadAddon(new WebLinksAddon());
  }

  open(container: HTMLElement) {
    this.term.open(container);
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

  setTheme(themeName: ThemeName, cursorColor: string): boolean {
    this.term.options.theme = terminalTheme(themeName, cursorColor) as ITheme;
    return true;
  }

  setLineHeight(value: number): boolean {
    this.term.options.lineHeight = value;
    return true;
  }

  setFont(fontFamily: string): boolean {
    this.term.options.fontFamily = fontFamily;
    return true;
  }

  dispose() {
    this.term.dispose();
  }
}

export function createXtermBackend(o: BackendOptions): TerminalBackend {
  return new XtermBackend(o);
}
