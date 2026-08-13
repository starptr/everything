// Shift-modified special-key encodings for the libghostty adapter, split out so it's unit-
// testable without importing ghostty-web (its ~400KB WASM must stay out of the bun test run —
// see backend.ts).
//
// ghostty-web's key fast-path fires for the "no modifier" AND "Shift only" cases together and
// emits the UNmodified sequence, so every Shift+<special> is wrong (Shift+Tab → plain tab,
// Shift+Home → bare Home, …) and never reaches its WASM key encoder. The adapter re-emits
// these with their standard xterm encodings (modifier param 2 = Shift; Tab uses the
// conventional CBT `ESC [ Z`). Everything else — printables, plain specials, arrows, and any
// Ctrl/Alt/Meta combo — already encodes correctly in ghostty, so those are left alone.
// Keyed by KeyboardEvent.key.
export const SHIFT_SPECIALS: Record<string, string> = {
  Tab: "\x1b[Z",
  Home: "\x1b[1;2H",
  End: "\x1b[1;2F",
  Insert: "\x1b[2;2~",
  Delete: "\x1b[3;2~",
  PageUp: "\x1b[5;2~",
  PageDown: "\x1b[6;2~",
  F1: "\x1b[1;2P",
  F2: "\x1b[1;2Q",
  F3: "\x1b[1;2R",
  F4: "\x1b[1;2S",
  F5: "\x1b[15;2~",
  F6: "\x1b[17;2~",
  F7: "\x1b[18;2~",
  F8: "\x1b[19;2~",
  F9: "\x1b[20;2~",
  F10: "\x1b[21;2~",
  F11: "\x1b[23;2~",
  F12: "\x1b[24;2~",
};
