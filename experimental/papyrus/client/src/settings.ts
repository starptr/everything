// Terminal appearance settings for papyrus.
//
// The first (and so far only) setting is line spacing — the xterm `lineHeight`
// multiplier. Persistence mirrors theme.ts: a lenient parse with a safe fallback so a
// bad localStorage entry can never wedge the app, and localStorage helpers guarded for
// environments without it. Values are clamped to a sane range and snapped to the step
// grid so the number stepper never drifts off round increments.

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
