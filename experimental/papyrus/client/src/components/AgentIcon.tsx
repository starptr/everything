import {
  Sparkles,
  Code,
  Cpu,
  Zap,
  Rocket,
  Bot,
  Brain,
  Wand2,
  type LucideIcon,
} from "lucide-react";

// String key -> lucide icon, shared by the canvas node and the pane title bar. Keys
// match the values written to node data (`node.data.icon`).
export const iconMap: Record<string, LucideIcon> = {
  sparkles: Sparkles,
  code: Code,
  cpu: Cpu,
  zap: Zap,
  rocket: Rocket,
  bot: Bot,
  brain: Brain,
  wand2: Wand2,
};

interface AgentIconProps {
  icon: string;
  color: string;
}

// The workstream's identity badge: its icon in a color-tinted rounded box. `color` is a
// hex string (the custom color); the box uses it at ~12% alpha, the icon at full.
export function AgentIcon({ icon, color }: AgentIconProps) {
  const Icon = iconMap[icon] || Cpu;
  return (
    <div
      className="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0"
      style={{ backgroundColor: `${color}20` }}
    >
      <Icon className="w-5 h-5" style={{ color }} />
    </div>
  );
}
