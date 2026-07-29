// The seam that makes papyrus's terminal emulator swappable at runtime.
//
// Every emulator API call in Terminal.tsx collapses into the ~10-method `TerminalBackend`
// below, so the component stays emulator-agnostic (WS wiring, ResizeObserver, injected
// control sequences) and only rendering is delegated to the selected backend. Each concrete
// adapter (and its heavy dependency tree — @xterm/* + CSS, or ghostty-web's ~400KB WASM) is
// reached ONLY through the dynamic import() in `createTerminalBackend`, so neither loads
// until a terminal actually mounts with that backend selected — and neither is ever pulled
// into the initial bundle or the (Terminal.tsx-mocked) bun test run.

import type { ThemeName } from "../theme";
import type { BackendId } from "../settings";
import type { TerminalPalette } from "./palette";

export type { BackendId };

// Exactly what Terminal.tsx configures on the emulator today.
export interface BackendOptions {
  fontSize: number;
  fontFamily: string;
  fontWeight: string;
  lineHeight: number;
  letterSpacing: number;
  cursorBlink: boolean;
  cursorStyle: "bar" | "block" | "underline";
  scrollback: number;
  allowProposedApi: boolean;
  theme: TerminalPalette; // resolved at construction
}

export interface TerminalSize {
  cols: number;
  rows: number;
}

// The minimal surface Terminal.tsx needs — nothing more.
export interface TerminalBackend {
  readonly id: BackendId;
  open(container: HTMLElement): void;
  write(data: string): void;
  onData(cb: (data: string) => void): void;
  fit(): void;
  readonly size: TerminalSize;
  // Update live if the backend supports it and return true; return false if it cannot, so
  // the caller remounts the pane at the new settings instead (graceful degradation).
  setTheme(themeName: ThemeName, cursorColor: string): boolean;
  setLineHeight(value: number): boolean;
  dispose(): void;
}

// Build the selected backend. Absorbs ghostty's async init(); xterm's path just resolves.
// The dynamic import()s are what keep each emulator out of any module graph that never
// calls this.
export async function createTerminalBackend(
  id: BackendId,
  opts: BackendOptions,
): Promise<TerminalBackend> {
  if (id === "ghostty") {
    const { createGhosttyBackend } = await import("./ghosttyBackend");
    return createGhosttyBackend(opts);
  }
  const { createXtermBackend } = await import("./xtermBackend");
  return createXtermBackend(opts);
}
