import { useEffect } from "react";
import { createPortal } from "react-dom";
import { Monitor, Sun, Moon, Check } from "lucide-react";
import {
  type ThemePreference,
  DEFAULT_SYSTEM_MAPPING,
} from "../theme";

// The quick 3-way theme switch. Each row maps to a concrete ThemePreference; the active
// one is checked. (A future settings surface can offer per-appearance theme choices by
// filling DEFAULT_SYSTEM_MAPPING's slots from the theme registry.)
interface ThemeOption {
  label: string;
  icon: typeof Monitor;
  preference: ThemePreference;
  isActive: (p: ThemePreference) => boolean;
}

const OPTIONS: ThemeOption[] = [
  {
    label: "System",
    icon: Monitor,
    preference: { mode: "system", mapping: DEFAULT_SYSTEM_MAPPING },
    isActive: (p) => p.mode === "system",
  },
  {
    label: "Light",
    icon: Sun,
    preference: { mode: "fixed", theme: "light" },
    isActive: (p) => p.mode === "fixed" && p.theme === "light",
  },
  {
    label: "Dark",
    icon: Moon,
    preference: { mode: "fixed", theme: "dark" },
    isActive: (p) => p.mode === "fixed" && p.theme === "dark",
  },
];

interface ThemeMenuProps {
  open: boolean;
  anchor: DOMRect | null;
  preference: ThemePreference;
  onPick: (pref: ThemePreference) => void;
  onClose: () => void;
}

const MENU_WIDTH = 176;

// Anchored dropdown under the header's theme button. Rendered in a body portal so it
// escapes the header; closes on outside-click or Escape. Mirrors NewSessionMenu.
export function ThemeMenu({ open, anchor, preference, onPick, onClose }: ThemeMenuProps) {
  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (!(e.target as HTMLElement).closest(".theme-menu")) onClose();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    // Defer the click listener a tick so the opening click doesn't close it.
    const t = setTimeout(() => window.addEventListener("click", onClick), 0);
    window.addEventListener("keydown", onKey);
    return () => {
      clearTimeout(t);
      window.removeEventListener("click", onClick);
      window.removeEventListener("keydown", onKey);
    };
  }, [open, onClose]);

  if (!open || !anchor) return null;

  // Right-align to the trigger (it sits at the header's right edge), clamped on-screen.
  const left = Math.max(8, Math.min(anchor.right - MENU_WIDTH, window.innerWidth - MENU_WIDTH - 8));
  const top = anchor.bottom + 4;

  return createPortal(
    <div
      className="theme-menu fixed z-[9999] rounded-lg border border-popover-border bg-popover shadow-xl py-1"
      style={{ left, top, width: MENU_WIDTH }}
    >
      {OPTIONS.map((opt) => {
        const Icon = opt.icon;
        const active = opt.isActive(preference);
        return (
          <button
            key={opt.label}
            onClick={() => {
              onPick(opt.preference);
              onClose();
            }}
            className="w-full px-3 py-2 text-left hover:bg-surface-active flex items-center gap-2.5 transition-colors"
          >
            <Icon className="w-4 h-4 flex-shrink-0 text-content-subtle" />
            <span className="flex-1 text-xs text-content">{opt.label}</span>
            {active && <Check className="w-3.5 h-3.5 flex-shrink-0 text-content" />}
          </button>
        );
      })}
    </div>,
    document.body,
  );
}
