// UNIT test (mine to maintain — see ../../../TESTING.md): the menu renders one row per
// session kind from silverwood's schema (a required bool option becomes two rows), and each
// row picks its { kind, options } then closes. The /api/session-schema fetch is stubbed to
// reject, so the menu falls back to FALLBACK_SESSION_SCHEMA (deterministic, no network).
import { describe, test, expect, mock, beforeEach, afterEach } from "bun:test";
import { render, screen, fireEvent } from "@testing-library/react";
import { NewSessionMenu } from "./NewSessionMenu";

const anchor = { bottom: 100, left: 40 } as DOMRect;

let originalFetch: typeof globalThis.fetch;
beforeEach(() => {
  originalFetch = globalThis.fetch;
  globalThis.fetch = mock(() => Promise.reject(new Error("no network in test"))) as any;
});
afterEach(() => {
  globalThis.fetch = originalFetch;
});

function renderMenu(open = true) {
  const onPick = mock((_: { kind: string; options: Record<string, string> }) => {});
  const onClose = mock(() => {});
  render(<NewSessionMenu open={open} anchor={anchor} onClose={onClose} onPick={onPick} />);
  return { onPick, onClose };
}

describe("NewSessionMenu", () => {
  test("renders a row per fallback kind, titled by the silverwood tag (noninteractive → two rows)", () => {
    renderMenu();
    expect(screen.getByText("claude-code")).not.toBeNull();
    expect(screen.getByText("plain-shell")).not.toBeNull();
    expect(screen.getByText("disk-space")).not.toBeNull();
    // The noninteractive kind's required bool option becomes two rows, differentiated by flag.
    expect(screen.getByText(/run-direnv-exec=true/)).not.toBeNull();
    expect(screen.getByText(/run-direnv-exec=false/)).not.toBeNull();
  });

  test("renders nothing when closed", () => {
    renderMenu(false);
    expect(screen.queryByText("plain-shell")).toBeNull();
  });

  test("picking claude-code fires onPick({ kind: 'claude-code', options: {} }) then onClose", () => {
    const { onPick, onClose } = renderMenu();
    fireEvent.click(screen.getByText("claude-code"));
    expect(onPick).toHaveBeenCalledWith({ kind: "claude-code", options: {} });
    expect(onClose).toHaveBeenCalled();
  });

  test("picking plain-shell fires onPick({ kind: 'plain-shell', options: {} }) then onClose", () => {
    const { onPick, onClose } = renderMenu();
    fireEvent.click(screen.getByText("plain-shell"));
    expect(onPick).toHaveBeenCalledWith({ kind: "plain-shell", options: {} });
    expect(onClose).toHaveBeenCalled();
  });

  test("picking a noninteractive row carries its run-direnv-exec option value", () => {
    const { onPick } = renderMenu();
    fireEvent.click(screen.getByText(/run-direnv-exec=true/));
    expect(onPick).toHaveBeenCalledWith({
      kind: "claude-code-noninteractive",
      options: { "run-direnv-exec": "true" },
    });
  });
});
