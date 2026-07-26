import { test, expect, describe } from "bun:test";
import { resolveReconciledPosition, type MoveGuard } from "./canvasPosition";

const at = (x: number, y: number) => ({ x, y });
const guard = (x: number, y: number, expiry: number): MoveGuard => ({ x, y, expiry });

describe("resolveReconciledPosition", () => {
  test("no guard: adopts silverwood when it differs (cross-instance move)", () => {
    // Another instance moved the node; we hold no guard, so silverwood wins.
    expect(resolveReconciledPosition(at(0, 0), at(24, 48), undefined, 1000)).toEqual({
      position: at(24, 48),
      clearGuard: false,
    });
  });

  test("no guard, already in sync: no update, nothing to clear", () => {
    expect(resolveReconciledPosition(at(24, 48), at(24, 48), undefined, 1000)).toEqual({
      clearGuard: false,
    });
  });

  test("guard matches server: our own save propagated — clear guard, no snap", () => {
    // We dragged to (96,-72), kept it locally, and silverwood now echoes it back.
    const r = resolveReconciledPosition(at(96, -72), at(96, -72), guard(96, -72, 9999), 1000);
    expect(r).toEqual({ clearGuard: true });
  });

  test("guard set, server still stale, before expiry: keep optimistic position", () => {
    // Our save hasn't landed yet; a stale in-flight read must NOT snap us back.
    const r = resolveReconciledPosition(at(96, -72), at(0, 0), guard(96, -72, 9999), 1000);
    expect(r).toEqual({ clearGuard: false });
    expect(r.position).toBeUndefined();
  });

  test("guard set, server changed by another instance, past expiry: trust server", () => {
    // Save apparently failed/clobbered; after the safety expiry, silverwood wins.
    const r = resolveReconciledPosition(at(96, -72), at(240, 240), guard(96, -72, 500), 1000);
    expect(r).toEqual({ position: at(240, 240), clearGuard: true });
  });

  test("no server position: leave the node alone, keep any guard", () => {
    expect(resolveReconciledPosition(at(10, 10), undefined, guard(96, -72, 9999), 1000)).toEqual({
      clearGuard: false,
    });
  });

  test("guard past expiry but server already matches local: clear guard, no update", () => {
    const r = resolveReconciledPosition(at(96, -72), at(96, -72), guard(96, -72, 500), 1000);
    expect(r).toEqual({ clearGuard: true });
  });
});
