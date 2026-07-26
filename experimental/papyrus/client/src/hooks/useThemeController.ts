import { useEffect } from "react";
import { useStore } from "../stores/useStore";
import { applyResolvedTheme, resolveTheme } from "../theme";

// Owns applying the active theme to <html>. Mount once (in App). Resolves the stored
// preference to a concrete theme name, writes `data-theme`, mirrors it into the store
// (so consumers like the terminal can react), and — while the preference follows the
// system — re-resolves live when the OS appearance changes.
export function useThemeController() {
  const themePreference = useStore((s) => s.themePreference);
  const setResolvedTheme = useStore((s) => s.setResolvedTheme);

  useEffect(() => {
    const mql = window.matchMedia?.("(prefers-color-scheme: dark)");

    const apply = () => {
      const name = resolveTheme(themePreference, mql?.matches ?? false);
      applyResolvedTheme(name);
      setResolvedTheme(name);
    };

    apply();

    // Only the system-following preference cares about OS appearance changes.
    if (themePreference.mode !== "system" || !mql) return;
    mql.addEventListener("change", apply);
    return () => mql.removeEventListener("change", apply);
  }, [themePreference, setResolvedTheme]);
}
