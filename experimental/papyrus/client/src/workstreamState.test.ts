import { test, expect, describe } from "bun:test";
import { workstreamStateLabel } from "./workstreamState";

const tab = (connected: boolean) => ({ connected });

describe("workstreamStateLabel", () => {
  test("basic + ready: shows only N/M Connected (base is omitted)", () => {
    const { label, color } = workstreamStateLabel({
      overallState: "active - basic.ready",
      kind: "basic",
      checkoutState: "ready",
      connected: true,
      tabs: [tab(true), tab(false), tab(true)],
    });
    expect(label).toBe("2/3 Connected");
    expect(color).toBe("#22C55E");
  });

  test("basic + ready with no agents: 0/0 Connected, gray (nothing connected)", () => {
    const { label, color } = workstreamStateLabel({
      overallState: "active - basic.ready",
      kind: "basic",
      checkoutState: "ready",
      connected: false,
      tabs: [],
    });
    expect(label).toBe("0/0 Connected");
    expect(color).toBe("#6B7280");
  });

  test("pending: base label only, amber", () => {
    const { label, color } = workstreamStateLabel({
      overallState: "active - basic.pending",
      kind: "basic",
      checkoutState: "pending",
      connected: false,
      tabs: [],
    });
    expect(label).toBe("active - basic.pending");
    expect(color).toBe("#FBBF24");
  });

  test("failed: base label only, red — even if a session is connected", () => {
    const { label, color } = workstreamStateLabel({
      overallState: "active - basic.failed",
      kind: "basic",
      checkoutState: "failed",
      connected: true,
      tabs: [tab(true)],
    });
    expect(label).toBe("active - basic.failed");
    expect(color).toBe("#EF4444");
  });

  test("non-basic kind that is ready: no N/M suffix", () => {
    const { label } = workstreamStateLabel({
      overallState: "active - basic-external",
      kind: "basic-external",
      checkoutState: "ready",
      connected: true,
      tabs: [tab(true)],
    });
    expect(label).toBe("active - basic-external");
  });

  test("missing overallState: degrades gracefully (no leading space)", () => {
    const { label } = workstreamStateLabel({
      kind: "basic",
      checkoutState: "ready",
      connected: true,
      tabs: [tab(true), tab(true)],
    });
    expect(label).toBe("2/2 Connected");
  });
});
