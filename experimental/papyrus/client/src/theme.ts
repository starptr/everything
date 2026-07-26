// Theming model for papyrus.
//
// A theme is an arbitrary *name* (e.g. "light", "dark"); each name has a matching
// `:root[data-theme="<name>"]` block of CSS variables in index.css. `data-theme` on
// <html> selects the active theme, so switching themes is a single attribute write and
// adding a theme is one registry entry + one CSS block — nothing else changes.
//
// The user's *preference* is a superset of a plain toggle: either a fixed theme, or
// "follow the system" with a mapping of which theme to use for the OS's light vs dark
// appearance. Today the UI exposes System / Light / Dark, but the model already supports
// e.g. mapping OS-light → "solarized-light" and OS-dark → "solarized-dark" later, with no
// refactor of the resolver, storage, or CSS.

export type ThemeName = string;

export type ThemePolarity = "light" | "dark";

export interface ThemeMeta {
  label: string;
  // Whether the theme reads as light or dark. Used to offer only sensible choices
  // for the system light/dark mapping (a future settings surface).
  polarity: ThemePolarity;
}

// The theme registry. Add a theme here (and a CSS block in index.css) to grow the set.
export const THEMES: Record<ThemeName, ThemeMeta> = {
  light: { label: "Light", polarity: "light" },
  dark: { label: "Dark", polarity: "dark" },
};

export interface SystemMapping {
  light: ThemeName;
  dark: ThemeName;
}

// When following the system, which concrete theme to use for each OS appearance.
export const DEFAULT_SYSTEM_MAPPING: SystemMapping = { light: "light", dark: "dark" };

export type ThemePreference =
  | { mode: "fixed"; theme: ThemeName }
  | { mode: "system"; mapping: SystemMapping };

export const DEFAULT_PREFERENCE: ThemePreference = {
  mode: "system",
  mapping: DEFAULT_SYSTEM_MAPPING,
};

export const THEME_STORAGE_KEY = "papyrus:theme";

const SYSTEM_DARK_QUERY = "(prefers-color-scheme: dark)";

// Does the OS currently prefer dark? Guarded for environments without matchMedia.
export function systemPrefersDark(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia(SYSTEM_DARK_QUERY).matches
  );
}

// Resolve a preference to the concrete theme name that should be applied.
export function resolveTheme(pref: ThemePreference, prefersDark: boolean): ThemeName {
  if (pref.mode === "fixed") return pref.theme;
  return prefersDark ? pref.mapping.dark : pref.mapping.light;
}

// A lenient parse: unknown/legacy/corrupt values fall back to follow-system rather than
// throwing, so a bad localStorage entry can never wedge the app.
export function parseThemePreference(raw: string | null): ThemePreference {
  if (!raw) return DEFAULT_PREFERENCE;
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    return DEFAULT_PREFERENCE;
  }
  if (!data || typeof data !== "object") return DEFAULT_PREFERENCE;
  const obj = data as Record<string, unknown>;
  if (obj.mode === "fixed" && typeof obj.theme === "string") {
    return { mode: "fixed", theme: obj.theme };
  }
  if (obj.mode === "system") {
    const m = obj.mapping as Record<string, unknown> | undefined;
    return {
      mode: "system",
      mapping: {
        light: typeof m?.light === "string" ? m.light : DEFAULT_SYSTEM_MAPPING.light,
        dark: typeof m?.dark === "string" ? m.dark : DEFAULT_SYSTEM_MAPPING.dark,
      },
    };
  }
  return DEFAULT_PREFERENCE;
}

export function loadThemePreference(): ThemePreference {
  if (typeof localStorage === "undefined") return DEFAULT_PREFERENCE;
  return parseThemePreference(localStorage.getItem(THEME_STORAGE_KEY));
}

export function saveThemePreference(pref: ThemePreference): void {
  if (typeof localStorage === "undefined") return;
  localStorage.setItem(THEME_STORAGE_KEY, JSON.stringify(pref));
}

// Apply a resolved theme name to the document root.
export function applyResolvedTheme(name: ThemeName): void {
  if (typeof document !== "undefined") {
    document.documentElement.dataset.theme = name;
  }
}
