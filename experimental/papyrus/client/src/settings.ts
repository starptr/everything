// Terminal settings for papyrus: the emulator backend and the line-spacing multiplier.
//
// Persistence mirrors theme.ts throughout: a lenient parse with a safe fallback so a bad
// localStorage entry can never wedge the app, and localStorage helpers guarded for
// environments without it. Line-spacing values are additionally clamped to a sane range
// and snapped to the step grid so the number stepper never drifts off round increments.

export const LINE_SPACING_STORAGE_KEY = "papyrus:lineSpacing";

export const MIN_LINE_SPACING = 1.0;
export const MAX_LINE_SPACING = 2.0;
export const LINE_SPACING_STEP = 0.05;
// 1.0 is xterm's native line height: box-drawing/ASCII art connects vertically.
export const DEFAULT_LINE_SPACING = 1.0;

// Clamp to [MIN, MAX] and snap to the step grid, rounding to 2 decimals so repeated
// stepping can't accumulate float error. Non-finite input falls back to the default.
export function clampLineSpacing(n: number): number {
  if (!Number.isFinite(n)) return DEFAULT_LINE_SPACING;
  const clamped = Math.min(MAX_LINE_SPACING, Math.max(MIN_LINE_SPACING, n));
  const snapped = Math.round(clamped / LINE_SPACING_STEP) * LINE_SPACING_STEP;
  return Math.round(snapped * 100) / 100;
}

// A lenient parse: missing/NaN/corrupt values fall back to the default rather than
// throwing, mirroring parseThemePreference.
export function parseLineSpacing(raw: string | null): number {
  if (raw === null) return DEFAULT_LINE_SPACING;
  const n = Number(raw);
  if (!Number.isFinite(n)) return DEFAULT_LINE_SPACING;
  return clampLineSpacing(n);
}

export function loadLineSpacing(): number {
  if (typeof localStorage === "undefined") return DEFAULT_LINE_SPACING;
  return parseLineSpacing(localStorage.getItem(LINE_SPACING_STORAGE_KEY));
}

export function saveLineSpacing(value: number): void {
  if (typeof localStorage === "undefined") return;
  localStorage.setItem(LINE_SPACING_STORAGE_KEY, String(clampLineSpacing(value)));
}

// --- Terminal emulator backend ---
//
// Which client-side VT engine renders the panes. `xterm` is the default; `ghostty` is
// libghostty (Ghostty's engine) via the ghostty-web WASM build. Selected at runtime.

export type BackendId = "xterm" | "ghostty";

export const TERMINAL_BACKEND_STORAGE_KEY = "papyrus:terminalBackend";
export const DEFAULT_TERMINAL_BACKEND: BackendId = "xterm";

// Display metadata for the Settings toggle. Icons are mapped in SettingsPanel so this
// module stays free of any React/emulator import.
export const TERMINAL_BACKENDS: { id: BackendId; label: string }[] = [
  { id: "xterm", label: "xterm.js" },
  { id: "ghostty", label: "libghostty" },
];

// A lenient parse: unknown/legacy/corrupt values fall back to the default backend.
export function parseTerminalBackend(raw: string | null): BackendId {
  return TERMINAL_BACKENDS.some((b) => b.id === raw)
    ? (raw as BackendId)
    : DEFAULT_TERMINAL_BACKEND;
}

export function loadTerminalBackend(): BackendId {
  if (typeof localStorage === "undefined") return DEFAULT_TERMINAL_BACKEND;
  return parseTerminalBackend(localStorage.getItem(TERMINAL_BACKEND_STORAGE_KEY));
}

export function saveTerminalBackend(id: BackendId): void {
  if (typeof localStorage === "undefined") return;
  localStorage.setItem(TERMINAL_BACKEND_STORAGE_KEY, id);
}

// --- Terminal font ---
//
// The font each emulator renders with, chosen per-emulator. Every entry is self-hosted:
// bundled from nixpkgs by the flake (`terminalFonts`) and served at /fonts/*.ttf via the
// @font-face rules in index.css, so each ships real Regular/Bold/Italic/BoldItalic faces
// (no browser synthesis). "…Mono" variants keep Nerd Font icon glyphs single-cell.

export type FontId =
  | "jetbrains-mono"
  | "iosevka"
  | "iosevka-mono"
  | "iosevka-term"
  | "iosevka-term-mono";

export const XTERM_FONT_STORAGE_KEY = "papyrus:xtermFont";
export const GHOSTTY_FONT_STORAGE_KEY = "papyrus:ghosttyFont";
export const DEFAULT_FONT: FontId = "jetbrains-mono";

// Display metadata + the CSS stack each id resolves to (self-hosted family first, monospace
// as the last-resort fallback). Array order is the order shown in the Settings font picker.
export const TERMINAL_FONTS: { id: FontId; label: string; stack: string }[] = [
  { id: "jetbrains-mono", label: "JetBrains Mono", stack: '"JetBrains Mono", monospace' },
  { id: "iosevka", label: "Iosevka Nerd Font", stack: '"Iosevka Nerd Font", monospace' },
  {
    id: "iosevka-mono",
    label: "Iosevka Nerd Font Mono",
    stack: '"Iosevka Nerd Font Mono", monospace',
  },
  {
    id: "iosevka-term",
    label: "IosevkaTerm Nerd Font",
    stack: '"IosevkaTerm Nerd Font", monospace',
  },
  {
    id: "iosevka-term-mono",
    label: "IosevkaTerm Nerd Font Mono",
    stack: '"IosevkaTerm Nerd Font Mono", monospace',
  },
];

// A lenient parse: unknown/legacy/corrupt values fall back to the default font.
export function parseFont(raw: string | null): FontId {
  return TERMINAL_FONTS.some((f) => f.id === raw) ? (raw as FontId) : DEFAULT_FONT;
}

// Load/save are parametric on the storage key so xterm and ghostty each persist their own.
export function loadFont(storageKey: string): FontId {
  if (typeof localStorage === "undefined") return DEFAULT_FONT;
  return parseFont(localStorage.getItem(storageKey));
}

export function saveFont(storageKey: string, id: FontId): void {
  if (typeof localStorage === "undefined") return;
  localStorage.setItem(storageKey, id);
}

// Resolve a font id to its CSS font-family stack (falling back to the default's).
export function fontStack(id: FontId): string {
  return (TERMINAL_FONTS.find((f) => f.id === id) ?? TERMINAL_FONTS[0]).stack;
}
