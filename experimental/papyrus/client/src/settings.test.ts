// UNIT test (mine to maintain — see ../../TESTING.md): the clamp/step-snap and the
// tolerant (de)serialization that back the line-spacing stepper and the emulator toggle.
import { describe, test, expect, beforeEach } from "bun:test";
import {
  DEFAULT_LINE_SPACING,
  DEFAULT_TERMINAL_BACKEND,
  LINE_SPACING_STORAGE_KEY,
  MAX_LINE_SPACING,
  MIN_LINE_SPACING,
  TERMINAL_BACKEND_STORAGE_KEY,
  clampLineSpacing,
  loadLineSpacing,
  loadTerminalBackend,
  parseLineSpacing,
  parseTerminalBackend,
  saveLineSpacing,
  saveTerminalBackend,
} from "./settings";

describe("clampLineSpacing", () => {
  test("clamps below the minimum up to MIN", () => {
    expect(clampLineSpacing(0.5)).toBe(MIN_LINE_SPACING);
  });

  test("clamps above the maximum down to MAX", () => {
    expect(clampLineSpacing(5)).toBe(MAX_LINE_SPACING);
  });

  test("snaps to the step grid, rounding to 2 decimals", () => {
    expect(clampLineSpacing(1.23)).toBe(1.25);
    // Guard against float drift accumulating off round increments.
    expect(clampLineSpacing(1.0500000000000003)).toBe(1.05);
  });

  test("passes a valid on-grid value through unchanged", () => {
    expect(clampLineSpacing(1.4)).toBe(1.4);
  });

  test("non-finite input falls back to the default", () => {
    expect(clampLineSpacing(NaN)).toBe(DEFAULT_LINE_SPACING);
    expect(clampLineSpacing(Infinity)).toBe(DEFAULT_LINE_SPACING);
  });
});

describe("parseLineSpacing", () => {
  test("null (nothing stored) falls back to the default", () => {
    expect(parseLineSpacing(null)).toBe(DEFAULT_LINE_SPACING);
  });

  test("garbage falls back to the default rather than throwing", () => {
    expect(parseLineSpacing("not a number")).toBe(DEFAULT_LINE_SPACING);
    expect(parseLineSpacing("")).toBe(DEFAULT_LINE_SPACING);
  });

  test("a valid string round-trips through the clamp", () => {
    expect(parseLineSpacing("1.25")).toBe(1.25);
    expect(parseLineSpacing("9")).toBe(MAX_LINE_SPACING);
  });
});

describe("loadLineSpacing / saveLineSpacing", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  test("defaults when nothing is stored", () => {
    expect(loadLineSpacing()).toBe(DEFAULT_LINE_SPACING);
  });

  test("persists under the papyrus:lineSpacing key and reads back", () => {
    saveLineSpacing(1.3);
    expect(localStorage.getItem(LINE_SPACING_STORAGE_KEY)).toBe("1.3");
    expect(loadLineSpacing()).toBe(1.3);
  });

  test("save clamps out-of-range values before persisting", () => {
    saveLineSpacing(10);
    expect(loadLineSpacing()).toBe(MAX_LINE_SPACING);
  });
});

describe("parseTerminalBackend", () => {
  test("null (nothing stored) falls back to the default backend", () => {
    expect(parseTerminalBackend(null)).toBe(DEFAULT_TERMINAL_BACKEND);
  });

  test("a known backend id passes through", () => {
    expect(parseTerminalBackend("xterm")).toBe("xterm");
    expect(parseTerminalBackend("ghostty")).toBe("ghostty");
  });

  test("an unknown id falls back to the default rather than passing through", () => {
    expect(parseTerminalBackend("kitty")).toBe(DEFAULT_TERMINAL_BACKEND);
    expect(parseTerminalBackend("")).toBe(DEFAULT_TERMINAL_BACKEND);
  });
});

describe("loadTerminalBackend / saveTerminalBackend", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  test("defaults when nothing is stored", () => {
    expect(loadTerminalBackend()).toBe(DEFAULT_TERMINAL_BACKEND);
  });

  test("persists under the papyrus:terminalBackend key and reads back", () => {
    saveTerminalBackend("ghostty");
    expect(localStorage.getItem(TERMINAL_BACKEND_STORAGE_KEY)).toBe("ghostty");
    expect(loadTerminalBackend()).toBe("ghostty");
  });

  test("a corrupt stored value loads as the default", () => {
    localStorage.setItem(TERMINAL_BACKEND_STORAGE_KEY, "bogus");
    expect(loadTerminalBackend()).toBe(DEFAULT_TERMINAL_BACKEND);
  });
});
