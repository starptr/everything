// UNIT test (mine to maintain — see ../../TESTING.md): the clamp/step-snap and the
// tolerant (de)serialization that back the line-spacing stepper, the emulator toggle, the
// per-emulator font pickers, and the per-(emulator, font) font-size stepper.
import { describe, test, expect, beforeEach } from "bun:test";
import {
  DEFAULT_FONT,
  DEFAULT_FONT_SIZE,
  DEFAULT_LINE_SPACING,
  DEFAULT_TERMINAL_BACKEND,
  FONT_SIZE_STORAGE_KEY,
  GHOSTTY_FONT_STORAGE_KEY,
  LINE_SPACING_STORAGE_KEY,
  MAX_FONT_SIZE,
  MAX_LINE_SPACING,
  MIN_FONT_SIZE,
  MIN_LINE_SPACING,
  TERMINAL_BACKEND_STORAGE_KEY,
  XTERM_FONT_STORAGE_KEY,
  clampFontSize,
  clampLineSpacing,
  fontSizeFor,
  fontSizeKey,
  fontStack,
  loadFont,
  loadFontSizes,
  loadLineSpacing,
  loadTerminalBackend,
  parseFont,
  parseFontSizes,
  parseLineSpacing,
  parseTerminalBackend,
  saveFont,
  saveFontSizes,
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

describe("parseFont", () => {
  test("null (nothing stored) falls back to the default font", () => {
    expect(parseFont(null)).toBe(DEFAULT_FONT);
  });

  test("known font ids pass through", () => {
    expect(parseFont("iosevka")).toBe("iosevka");
    expect(parseFont("iosevka-term-mono")).toBe("iosevka-term-mono");
  });

  test("an unknown id falls back to the default rather than passing through", () => {
    expect(parseFont("comic-sans")).toBe(DEFAULT_FONT);
    expect(parseFont("")).toBe(DEFAULT_FONT);
  });
});

describe("loadFont / saveFont", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  test("defaults when nothing is stored", () => {
    expect(loadFont(XTERM_FONT_STORAGE_KEY)).toBe(DEFAULT_FONT);
    expect(loadFont(GHOSTTY_FONT_STORAGE_KEY)).toBe(DEFAULT_FONT);
  });

  test("each emulator persists independently under its own key", () => {
    saveFont(XTERM_FONT_STORAGE_KEY, "iosevka");
    saveFont(GHOSTTY_FONT_STORAGE_KEY, "iosevka-term-mono");
    expect(localStorage.getItem(XTERM_FONT_STORAGE_KEY)).toBe("iosevka");
    expect(loadFont(XTERM_FONT_STORAGE_KEY)).toBe("iosevka");
    expect(loadFont(GHOSTTY_FONT_STORAGE_KEY)).toBe("iosevka-term-mono");
  });

  test("a corrupt stored value loads as the default", () => {
    localStorage.setItem(XTERM_FONT_STORAGE_KEY, "bogus");
    expect(loadFont(XTERM_FONT_STORAGE_KEY)).toBe(DEFAULT_FONT);
  });
});

describe("fontStack", () => {
  test("resolves a known id to its self-hosted CSS stack", () => {
    expect(fontStack("iosevka-term-mono")).toBe('"IosevkaTerm Nerd Font Mono", monospace');
    expect(fontStack(DEFAULT_FONT)).toBe('"JetBrains Mono", monospace');
  });
});

describe("clampFontSize", () => {
  test("clamps below the minimum up to MIN", () => {
    expect(clampFontSize(1)).toBe(MIN_FONT_SIZE);
  });

  test("clamps above the maximum down to MAX", () => {
    expect(clampFontSize(999)).toBe(MAX_FONT_SIZE);
  });

  test("rounds to a whole pixel", () => {
    expect(clampFontSize(13.4)).toBe(13);
    expect(clampFontSize(13.6)).toBe(14);
  });

  test("passes a valid whole value through unchanged", () => {
    expect(clampFontSize(16)).toBe(16);
  });

  test("non-finite input falls back to the default", () => {
    expect(clampFontSize(NaN)).toBe(DEFAULT_FONT_SIZE);
    expect(clampFontSize(Infinity)).toBe(DEFAULT_FONT_SIZE);
  });
});

describe("parseFontSizes", () => {
  test("null (nothing stored) yields an empty map", () => {
    expect(parseFontSizes(null)).toEqual({});
  });

  test("corrupt JSON or a non-object yields an empty map rather than throwing", () => {
    expect(parseFontSizes("not json")).toEqual({});
    expect(parseFontSizes("42")).toEqual({});
    expect(parseFontSizes("null")).toEqual({});
  });

  test("drops entries whose value isn't a finite number", () => {
    expect(parseFontSizes('{"xterm:iosevka":"big","ghostty:iosevka":15}')).toEqual({
      "ghostty:iosevka": 15,
    });
  });

  test("clamps surviving values into range", () => {
    expect(parseFontSizes('{"xterm:iosevka":999}')).toEqual({
      "xterm:iosevka": MAX_FONT_SIZE,
    });
  });
});

describe("loadFontSizes / saveFontSizes", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  test("defaults to an empty map when nothing is stored", () => {
    expect(loadFontSizes()).toEqual({});
  });

  test("persists the whole map under the papyrus:fontSizes key and reads back", () => {
    const map = { "xterm:iosevka": 14, "ghostty:jetbrains-mono": 18 };
    saveFontSizes(map);
    expect(localStorage.getItem(FONT_SIZE_STORAGE_KEY)).toBe(JSON.stringify(map));
    expect(loadFontSizes()).toEqual(map);
  });

  test("a corrupt stored value loads as an empty map", () => {
    localStorage.setItem(FONT_SIZE_STORAGE_KEY, "{bogus");
    expect(loadFontSizes()).toEqual({});
  });
});

describe("fontSizeFor / fontSizeKey", () => {
  test("keys a pair as `${backend}:${font}`", () => {
    expect(fontSizeKey("xterm", "iosevka")).toBe("xterm:iosevka");
  });

  test("an unset pair falls back to the default size", () => {
    expect(fontSizeFor({}, "xterm", "iosevka")).toBe(DEFAULT_FONT_SIZE);
  });

  test("each (emulator, font) pair resolves its own stored size", () => {
    const map = { "xterm:iosevka": 14, "ghostty:iosevka": 20, "xterm:jetbrains-mono": 11 };
    expect(fontSizeFor(map, "xterm", "iosevka")).toBe(14);
    expect(fontSizeFor(map, "ghostty", "iosevka")).toBe(20);
    expect(fontSizeFor(map, "xterm", "jetbrains-mono")).toBe(11);
    // A pair absent from the map still defaults.
    expect(fontSizeFor(map, "ghostty", "jetbrains-mono")).toBe(DEFAULT_FONT_SIZE);
  });
});
