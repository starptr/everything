// The silverwood CLI contract, driven through papyrus's own wrapper against a real
// binary + a temp forest. This is the direct regression guard for "silverwood changed
// its CLI": every argv the wrapper builds is exercised end-to-end. Skip-mode only, so
// nothing clones — runs in the network-isolated sandbox. Imports no native module.

import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import * as sw from "../server/services/silverwood";
import { newForest, cleanupForest, cli, SKIP_SOURCE } from "./helpers/forest";

function newSkipWs(name: string) {
  // Mirrors what POST /api/sessions passes: variant path + positional source.
  return sw.create({ name, path: ["basic", "jj-colocated"], args: [SKIP_SOURCE] });
}

describe("silverwood wrapper contract (skip-mode, no network)", () => {
  let dir: string;
  beforeEach(() => {
    dir = newForest();
  });
  afterEach(() => cleanupForest(dir));

  test("create → get → list round-trip", async () => {
    const ws = await newSkipWs("alpha");
    expect(ws.name).toBe("alpha");
    expect(ws.status).toBe("active");
    expect(sw.checkoutState(ws)).toBe("initialized-without-checkout");

    const got = await sw.get(ws.id);
    expect(got.id).toBe(ws.id);
    expect(got.name).toBe("alpha");

    const ids = (await sw.list()).map((w) => w.id);
    expect(ids).toContain(ws.id);
  });

  test("rename persists", async () => {
    const ws = await newSkipWs("before");
    await sw.rename(ws.id, "after");
    expect((await sw.get(ws.id)).name).toBe("after");
  });

  test("archive hides from list but survives as archived", async () => {
    const ws = await newSkipWs("doomed");
    await sw.archive(ws.id);
    expect((await sw.list()).map((w) => w.id)).not.toContain(ws.id);
    // Ground truth straight from silverwood: still present, tombstoned.
    const all = cli(["ls", "--all"]).json as Array<{ id: string; status: string }>;
    expect(all.find((w) => w.id === ws.id)?.status).toBe("archived");
  });

  test("kv set/get/unset round-trip in the papyrus namespace", async () => {
    const ws = await newSkipWs("kv");
    await sw.setKv(ws.id, "color", "#abcdef");
    await sw.setKv(ws.id, "position", { x: 1, y: 2 });

    let kv = await sw.getPapyrusKv(ws.id);
    expect(sw.decodeKv<string>(kv, "color")).toBe("#abcdef");
    expect(sw.decodeKv<{ x: number; y: number }>(kv, "position")).toEqual({ x: 1, y: 2 });

    await sw.unsetKv(ws.id, "color");
    kv = await sw.getPapyrusKv(ws.id);
    expect(sw.decodeKv<string>(kv, "color")).toBeUndefined();
  });

  test("session create/ls/rename/rm lifecycle (kind preserved)", async () => {
    const ws = await newSkipWs("sessions");
    const sid = crypto.randomUUID();
    await sw.sessionCreate("plain-shell", ws.id, sid, "shell");

    let sessions = await sw.sessionLs(ws.id);
    expect(sessions[sid]?.name).toBe("shell");
    expect(sessions[sid]?.kind).toBe("plain-shell");

    await sw.sessionRename(ws.id, sid, "renamed");
    sessions = await sw.sessionLs(ws.id);
    expect(sessions[sid]?.name).toBe("renamed");
    expect(sessions[sid]?.kind).toBe("plain-shell");

    await sw.sessionRemove(ws.id, sid);
    expect(await sw.sessionLs(ws.id)).not.toHaveProperty(sid);
  });

  test("session lock/unlock advisory lifecycle", async () => {
    const ws = await newSkipWs("lock");
    const sid = crypto.randomUUID();
    await sw.sessionCreate("claude-code", ws.id, sid, "claude");

    await sw.sessionLock(ws.id, sid, "holder-A");
    expect((await sw.sessionLs(ws.id))[sid]?.lock?.holder).toBe("holder-A");

    await sw.sessionUnlock(ws.id, sid, "holder-A");
    expect((await sw.sessionLs(ws.id))[sid]?.lock).toBeUndefined();
  });
});
