// The ANSI palette a terminal emulator renders with, plus the theme→palette mapping.
//
// Emulators need concrete color strings (not CSS vars), so we keep one palette per
// polarity and pick by the active theme. `TerminalPalette` is structurally the subset of
// xterm's `ITheme` we use, but is defined locally so this module pulls in NO emulator —
// making it safe to import from any backend (xterm spreads it into `ITheme`; ghostty reads
// only background/foreground).

import { THEMES, type ThemeName } from "../theme";

export interface TerminalPalette {
  background: string;
  foreground: string;
  selectionBackground?: string;
  selectionForeground?: string;
  cursor?: string;
  cursorAccent?: string;
  black: string;
  red: string;
  green: string;
  yellow: string;
  blue: string;
  magenta: string;
  cyan: string;
  white: string;
  brightBlack: string;
  brightRed: string;
  brightGreen: string;
  brightYellow: string;
  brightBlue: string;
  brightMagenta: string;
  brightCyan: string;
  brightWhite: string;
}

const DARK_PALETTE: TerminalPalette = {
  background: "#0d0d0d",
  foreground: "#d4d4d4",
  selectionBackground: "#3b3b3b",
  selectionForeground: "#ffffff",
  black: "#1a1a1a",
  red: "#f87171",
  green: "#4ade80",
  yellow: "#fbbf24",
  blue: "#60a5fa",
  magenta: "#c084fc",
  cyan: "#22d3ee",
  white: "#d4d4d4",
  brightBlack: "#525252",
  brightRed: "#fca5a5",
  brightGreen: "#86efac",
  brightYellow: "#fcd34d",
  brightBlue: "#93c5fd",
  brightMagenta: "#d8b4fe",
  brightCyan: "#67e8f9",
  brightWhite: "#ffffff",
};

const LIGHT_PALETTE: TerminalPalette = {
  background: "#fafafa",
  foreground: "#24292e",
  selectionBackground: "#cfe0f4",
  black: "#24292e",
  red: "#d73a49",
  green: "#22863a",
  yellow: "#b08800",
  blue: "#0366d6",
  magenta: "#6f42c1",
  cyan: "#1b7c83",
  white: "#6a737d",
  brightBlack: "#959da5",
  brightRed: "#cb2431",
  brightGreen: "#28a745",
  brightYellow: "#b08800",
  brightBlue: "#005cc5",
  brightMagenta: "#5a32a3",
  brightCyan: "#3192aa",
  brightWhite: "#24292e",
};

// Pick a palette by the active theme's polarity and set the cursor to the node's accent.
export function terminalTheme(themeName: ThemeName, cursorColor: string): TerminalPalette {
  const base = (THEMES[themeName]?.polarity ?? "dark") === "light" ? LIGHT_PALETTE : DARK_PALETTE;
  return { ...base, cursor: cursorColor, cursorAccent: base.background };
}
