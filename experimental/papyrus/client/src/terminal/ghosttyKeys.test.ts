// UNIT test (mine to maintain — see ../../../TESTING.md): the libghostty adapter's fix for
// Shift-modified special keys, which ghostty-web otherwise emits UNmodified.
import { describe, test, expect } from "bun:test";
import { SHIFT_SPECIALS } from "./ghosttyKeys";

describe("SHIFT_SPECIALS", () => {
  test("Shift+Tab is the conventional back-tab (CBT), not a literal tab", () => {
    expect(SHIFT_SPECIALS.Tab).toBe("\x1b[Z");
    expect(SHIFT_SPECIALS.Tab).not.toBe("\t");
  });

  test("edit/nav keys carry the Shift modifier param (;2)", () => {
    expect(SHIFT_SPECIALS.Home).toBe("\x1b[1;2H");
    expect(SHIFT_SPECIALS.End).toBe("\x1b[1;2F");
    expect(SHIFT_SPECIALS.PageUp).toBe("\x1b[5;2~");
    expect(SHIFT_SPECIALS.PageDown).toBe("\x1b[6;2~");
    expect(SHIFT_SPECIALS.Insert).toBe("\x1b[2;2~");
    expect(SHIFT_SPECIALS.Delete).toBe("\x1b[3;2~");
  });

  test("F1–F12 use the modified forms (F1–F4 as CSI, F5+ as CSI ~)", () => {
    expect(SHIFT_SPECIALS.F1).toBe("\x1b[1;2P");
    expect(SHIFT_SPECIALS.F4).toBe("\x1b[1;2S");
    expect(SHIFT_SPECIALS.F5).toBe("\x1b[15;2~");
    expect(SHIFT_SPECIALS.F12).toBe("\x1b[24;2~");
  });

  test("every entry is an escape sequence and none is a bare/unmodified byte", () => {
    for (const [key, seq] of Object.entries(SHIFT_SPECIALS)) {
      expect(seq.startsWith("\x1b[")).toBe(true);
      // Tab is CBT; the rest all carry the ;2 Shift modifier.
      if (key !== "Tab") expect(seq).toContain(";2");
    }
  });
});
