// The workstream-level state indicator shown on the canvas node banner and in the
// sidebar header. The label is silverwood's algebraic state string (e.g.
// `active - basic.ready`), plus — for a Basic workstream that is Ready — a
// `N/M Connected` agent count (N connected, M total). The color keeps the prior
// indicator precedence: checkout problems first, then whether a session is connected.

export interface WorkstreamStateInput {
  overallState?: string;
  kind?: string;
  checkoutState?: string;
  connected: boolean;
  tabs?: { connected: boolean }[];
}

export function workstreamStateLabel(input: WorkstreamStateInput): {
  label: string;
  color: string;
} {
  const { overallState, kind, checkoutState, connected, tabs = [] } = input;

  // The only state carrying a connection count is Basic + Ready; there we show just
  // "N/M Connected" and omit the (redundant) `active - basic.ready` base. Every other
  // state shows the algebraic string alone.
  let label = overallState ?? "";
  if (kind === "basic" && checkoutState === "ready") {
    const n = tabs.filter((t) => t.connected).length;
    label = `${n}/${tabs.length} Connected`;
  }

  const color =
    checkoutState === "failed"
      ? "#EF4444"
      : checkoutState === "pending"
        ? "#FBBF24"
        : connected
          ? "#22C55E"
          : "#6B7280";

  return { label, color };
}
