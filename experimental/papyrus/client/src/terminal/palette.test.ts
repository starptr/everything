// UNIT test (mine to maintain — see ../../../TESTING.md): the theme→palette mapping that
// both terminal backends share (polarity selection + cursor/cursorAccent).
import { describe, test, expect } from "bun:test";
import { terminalTheme } from "./palette";

describe("terminalTheme", () => {
  test("dark theme picks the dark palette", () => {
    const t = terminalTheme("dark", "#ff0000");
    expect(t.background).toBe("#0d0d0d");
    expect(t.foreground).toBe("#d4d4d4");
  });

  test("light theme picks the light palette", () => {
    const t = terminalTheme("light", "#ff0000");
    expect(t.background).toBe("#fafafa");
    expect(t.foreground).toBe("#24292e");
  });

  test("an unknown theme name falls back to the dark palette", () => {
    expect(terminalTheme("chartreuse", "#ff0000").background).toBe("#0d0d0d");
  });

  test("cursor is the passed accent and cursorAccent is the background", () => {
    const dark = terminalTheme("dark", "#22c55e");
    expect(dark.cursor).toBe("#22c55e");
    expect(dark.cursorAccent).toBe("#0d0d0d");

    const light = terminalTheme("light", "#22c55e");
    expect(light.cursor).toBe("#22c55e");
    expect(light.cursorAccent).toBe("#fafafa");
  });
});
