// BEHAVIORAL test (developer-owned — see ../../../TESTING.md). Pins the invariant:
// an open session-rename pane must close when you switch to a DIFFERENT tab, but
// stay open when you click the tab you're already editing.
import { describe, test, expect, mock } from "bun:test";
import { render, screen, fireEvent } from "@testing-library/react";
import { useStore } from "../../src/stores/useStore";
import type { AgentSession, SessionTab } from "../../src/stores/useStore";

// Stub the terminal so importing Sidebar doesn't pull @xterm/xterm + its CSS
// import. Must be registered before Sidebar is imported (bun mock.module is not
// hoisted), hence the dynamic import below.
mock.module("../../src/components/Terminal", () => ({ Terminal: () => null }));
const { Sidebar } = await import("../../src/components/Sidebar");

const tab = (sessionId: string, name: string): SessionTab => ({
  sessionId,
  name,
  createdAt: new Date(0).toISOString(),
  kind: "claude-code",
  connected: false,
  lock: null,
});

function seedTwoTabs() {
  const ws: AgentSession = {
    id: "ws1",
    sessionId: "ws1",
    agentId: "claude",
    agentName: "Claude Code",
    command: "claude",
    color: "#888",
    createdAt: new Date(0).toISOString(),
    cwd: "/tmp/ws1",
    connected: false,
    tabs: [tab("A", "Session A"), tab("B", "Session B")],
  };
  useStore.setState({
    sidebarOpen: true,
    selectedNodeId: "ws1",
    nodes: [],
    sessions: new Map([["ws1", ws]]),
  });
}

const paneOpen = () => screen.queryByText("Session title") !== null;
const openRenameFor = (index: number) =>
  fireEvent.click(screen.getAllByTitle("Rename session")[index]);

describe("session rename pane", () => {
  test("closes when switching to a different tab", () => {
    seedTwoTabs();
    render(<Sidebar />);

    openRenameFor(0); // Session A's pencil
    expect(paneOpen()).toBe(true);

    fireEvent.click(screen.getByRole("button", { name: "Session B" }));
    expect(paneOpen()).toBe(false);
  });

  test("stays open when clicking the tab being edited", () => {
    seedTwoTabs();
    render(<Sidebar />);

    openRenameFor(0); // Session A's pencil (A is already the active tab)
    expect(paneOpen()).toBe(true);

    fireEvent.click(screen.getByRole("button", { name: "Session A" }));
    expect(paneOpen()).toBe(true);
  });
});
