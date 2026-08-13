import { useEffect } from "react";
import { createPortal } from "react-dom";
import {
  Terminal,
  Sparkles,
  Code,
  Cpu,
  Zap,
  Rocket,
  Bot,
  Brain,
  Wand2,
} from "lucide-react";
import { Agent } from "../stores/useStore";

// Icon-string → component, matching the canvas node's map (AgentNode/index.tsx).
const iconMap: Record<string, any> = {
  sparkles: Sparkles,
  code: Code,
  cpu: Cpu,
  zap: Zap,
  rocket: Rocket,
  bot: Bot,
  brain: Brain,
  wand2: Wand2,
  terminal: Terminal,
};

// One row in the picker. `variant` is the string POSTed to the server; the agent
// variant(s) map to the durable "claude-code" session, "plain-shell" to a durable
// `silverwood spawn` login shell.
interface VariantItem {
  variant: string;
  label: string;
  description: string;
  icon: string;
  color?: string;
}

interface NewSessionMenuProps {
  open: boolean;
  anchor: DOMRect | null;
  agents: Agent[];
  onClose: () => void;
  onPick: (variant: string) => void;
}

const MENU_WIDTH = 244;

// An anchored dropdown that opens under the "+" button, letting the user pick the
// session variant to start. Rows are the available agent session kinds (from
// `agents`) plus a static Plain shell. Rendered in a body portal so it escapes the
// sidebar's overflow; closes on outside-click or Escape.
export function NewSessionMenu({ open, anchor, agents, onClose, onPick }: NewSessionMenuProps) {
  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (!(e.target as HTMLElement).closest(".new-session-menu")) onClose();
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

  const items: VariantItem[] = [
    // Today silverwood has exactly one create-variant (claude-code); each agent
    // maps to it. Add a new agent/kind here to grow the picker.
    ...agents.map((a) => ({
      variant: "claude-code",
      label: a.name,
      description: a.description,
      icon: a.icon,
      color: a.color,
    })),
    {
      variant: "plain-shell",
      label: "Plain shell",
      description: "Login shell (silverwood spawn)",
      icon: "terminal",
    },
  ];

  const left = Math.max(8, Math.min(anchor.left, window.innerWidth - MENU_WIDTH - 8));
  const top = anchor.bottom + 4;

  return createPortal(
    <div
      className="new-session-menu fixed z-[9999] rounded-lg border border-popover-border bg-popover shadow-xl py-1"
      style={{ left, top, width: MENU_WIDTH }}
    >
      {items.map((item, i) => {
        const Icon = iconMap[item.icon] || Cpu;
        return (
          <button
            key={`${item.variant}:${i}`}
            onClick={() => {
              onPick(item.variant);
              onClose();
            }}
            className="w-full px-3 py-2 text-left hover:bg-surface-active flex items-start gap-2.5 transition-colors"
          >
            <Icon
              className="w-4 h-4 flex-shrink-0 mt-0.5"
              style={{ color: item.color || "rgb(var(--color-content-muted))" }}
            />
            <div className="min-w-0">
              <div className="text-xs text-content">{item.label}</div>
              <div className="text-[10px] text-content-subtle truncate">{item.description}</div>
            </div>
          </button>
        );
      })}
    </div>,
    document.body,
  );
}
