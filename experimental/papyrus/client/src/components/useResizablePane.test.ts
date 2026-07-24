// UNIT test (mine to maintain — see ../../../TESTING.md): the pure width-clamp
// helper and the drag behavior of the resizable-pane hook.
import { describe, test, expect, beforeEach } from "bun:test";
import { createElement } from "react";
import { render, screen, fireEvent } from "@testing-library/react";
import { clampWidth, useResizablePane } from "./useResizablePane";

describe("clampWidth", () => {
  test("passes a value already inside the range through unchanged", () => {
    expect(clampWidth(512, 360, 1200)).toBe(512);
  });

  test("raises a below-min value up to the min", () => {
    expect(clampWidth(200, 360, 1200)).toBe(360);
  });

  test("lowers an above-max value down to the max", () => {
    expect(clampWidth(2000, 360, 1200)).toBe(1200);
  });

  test("honors a viewport-derived max (window shrank below the stored width)", () => {
    // Callers pass max = Math.min(hardMax, window.innerWidth - margin).
    const viewportMax = Math.min(1200, 640 - 80);
    expect(clampWidth(1000, 360, viewportMax)).toBe(560);
  });

  test("returns the boundary values exactly", () => {
    expect(clampWidth(360, 360, 1200)).toBe(360);
    expect(clampWidth(1200, 360, 1200)).toBe(1200);
  });
});

// A minimal harness that renders the hook's grip so we can drive real pointer
// events (the same events the Sidebar's left-edge grip receives).
function Harness() {
  const { width, dragging, gripProps } = useResizablePane({
    storageKey: "papyrus:sidebarWidth",
    defaultWidth: 512,
    min: 360,
    max: 1200,
  });
  return createElement(
    "div",
    { "data-testid": "pane", style: { width } },
    createElement("div", {
      "data-testid": "grip",
      "data-dragging": dragging,
      ...gripProps,
    })
  );
}

describe("useResizablePane drag behavior", () => {
  beforeEach(() => {
    localStorage.clear();
    // A wide viewport so max is the hard cap (1200), not viewport-derived.
    Object.defineProperty(window, "innerWidth", { value: 2000, configurable: true });
  });

  test("dragging the left edge leftward widens the pane and persists on release", () => {
    render(createElement(Harness));
    const pane = screen.getByTestId("pane");
    const grip = screen.getByTestId("grip");

    expect(pane.style.width).toBe("512px");

    // Left edge dragged left by 200px (800 -> 600) => +200px wide.
    fireEvent.pointerDown(grip, { pointerId: 1, clientX: 800 });
    fireEvent.pointerMove(grip, { pointerId: 1, clientX: 600 });
    expect(pane.style.width).toBe("712px");
    expect(grip.getAttribute("data-dragging")).toBe("true");

    fireEvent.pointerUp(grip, { pointerId: 1, clientX: 600 });
    expect(grip.getAttribute("data-dragging")).toBe("false");
    expect(localStorage.getItem("papyrus:sidebarWidth")).toBe("712");
  });

  test("clamps to the min while dragging right past the floor", () => {
    render(createElement(Harness));
    const pane = screen.getByTestId("pane");
    const grip = screen.getByTestId("grip");

    // Drag right by 400px (800 -> 1200): 512 - 400 = 112, clamped up to min 360.
    fireEvent.pointerDown(grip, { pointerId: 1, clientX: 800 });
    fireEvent.pointerMove(grip, { pointerId: 1, clientX: 1200 });
    expect(pane.style.width).toBe("360px");
  });

  test("restores a persisted width on mount", () => {
    localStorage.setItem("papyrus:sidebarWidth", "640");
    render(createElement(Harness));
    expect(screen.getByTestId("pane").style.width).toBe("640px");
  });
});
