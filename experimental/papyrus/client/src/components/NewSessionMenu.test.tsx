// UNIT test (mine to maintain — see ../../../TESTING.md): the variant picker lists
// one row per agent plus a Plain shell, and each row picks its variant then closes.
import { describe, test, expect, mock } from "bun:test";
import { render, screen, fireEvent } from "@testing-library/react";
import { NewSessionMenu } from "./NewSessionMenu";
import type { Agent } from "../stores/useStore";

const agents: Agent[] = [
  {
    id: "claude",
    name: "Claude Code",
    command: "claude",
    description: "Anthropic's official CLI for Claude",
    color: "#F97316",
    icon: "sparkles",
  },
];

// A minimal anchor rect; only bottom/left are read for positioning.
const anchor = { bottom: 100, left: 40 } as DOMRect;

function renderMenu(open = true) {
  const onPick = mock(() => {});
  const onClose = mock(() => {});
  render(
    <NewSessionMenu
      open={open}
      anchor={anchor}
      agents={agents}
      onClose={onClose}
      onPick={onPick}
    />,
  );
  return { onPick, onClose };
}

describe("NewSessionMenu", () => {
  test("renders a row per agent plus Plain shell", () => {
    renderMenu();
    expect(screen.getByText("Claude Code")).not.toBeNull();
    expect(screen.getByText("Plain shell")).not.toBeNull();
  });

  test("renders nothing when closed", () => {
    renderMenu(false);
    expect(screen.queryByText("Plain shell")).toBeNull();
  });

  test("picking the agent row fires onPick('claude-code') then onClose", () => {
    const { onPick, onClose } = renderMenu();
    fireEvent.click(screen.getByText("Claude Code"));
    expect(onPick).toHaveBeenCalledWith("claude-code");
    expect(onClose).toHaveBeenCalled();
  });

  test("picking Plain shell fires onPick('shell') then onClose", () => {
    const { onPick, onClose } = renderMenu();
    fireEvent.click(screen.getByText("Plain shell"));
    expect(onPick).toHaveBeenCalledWith("shell");
    expect(onClose).toHaveBeenCalled();
  });
});
