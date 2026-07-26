// UNIT test (mine to maintain — see ../../TESTING.md): the pure theme resolver and the
// tolerant preference (de)serialization that backs the theme picker.
import { describe, test, expect, beforeEach } from "bun:test";
import {
  DEFAULT_PREFERENCE,
  DEFAULT_SYSTEM_MAPPING,
  THEME_STORAGE_KEY,
  loadThemePreference,
  parseThemePreference,
  resolveTheme,
  saveThemePreference,
  type ThemePreference,
} from "./theme";

describe("resolveTheme", () => {
  test("a fixed preference returns its theme regardless of OS appearance", () => {
    const pref: ThemePreference = { mode: "fixed", theme: "light" };
    expect(resolveTheme(pref, true)).toBe("light");
    expect(resolveTheme(pref, false)).toBe("light");
  });

  test("a system preference maps OS dark/light to the configured theme", () => {
    const pref: ThemePreference = { mode: "system", mapping: { light: "light", dark: "dark" } };
    expect(resolveTheme(pref, true)).toBe("dark");
    expect(resolveTheme(pref, false)).toBe("light");
  });

  test("a system preference honors a non-default mapping", () => {
    const pref: ThemePreference = {
      mode: "system",
      mapping: { light: "solarized-light", dark: "solarized-dark" },
    };
    expect(resolveTheme(pref, true)).toBe("solarized-dark");
    expect(resolveTheme(pref, false)).toBe("solarized-light");
  });
});

describe("parseThemePreference", () => {
  test("null (nothing stored) falls back to follow-system", () => {
    expect(parseThemePreference(null)).toEqual(DEFAULT_PREFERENCE);
  });

  test("malformed JSON falls back to follow-system rather than throwing", () => {
    expect(parseThemePreference("{not json")).toEqual(DEFAULT_PREFERENCE);
  });

  test("an unknown/legacy shape falls back to follow-system", () => {
    expect(parseThemePreference(JSON.stringify({ mode: "wat" }))).toEqual(DEFAULT_PREFERENCE);
    expect(parseThemePreference(JSON.stringify("dark"))).toEqual(DEFAULT_PREFERENCE);
  });

  test("round-trips a fixed preference", () => {
    const pref: ThemePreference = { mode: "fixed", theme: "dark" };
    expect(parseThemePreference(JSON.stringify(pref))).toEqual(pref);
  });

  test("round-trips a system preference", () => {
    const pref: ThemePreference = {
      mode: "system",
      mapping: { light: "light", dark: "dark" },
    };
    expect(parseThemePreference(JSON.stringify(pref))).toEqual(pref);
  });

  test("a system preference missing mapping slots is filled from the default", () => {
    const parsed = parseThemePreference(JSON.stringify({ mode: "system" }));
    expect(parsed).toEqual({ mode: "system", mapping: DEFAULT_SYSTEM_MAPPING });
  });
});

describe("loadThemePreference / saveThemePreference", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  test("defaults to follow-system when nothing is stored", () => {
    expect(loadThemePreference()).toEqual(DEFAULT_PREFERENCE);
  });

  test("persists under the papyrus:theme key and reads back", () => {
    const pref: ThemePreference = { mode: "fixed", theme: "light" };
    saveThemePreference(pref);
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe(JSON.stringify(pref));
    expect(loadThemePreference()).toEqual(pref);
  });
});
