// End-to-end through papyrus's real HTTP routes, driven in-process via Hono's test
// client against a real silverwood binary + a temp forest. Asserts that canvas CUJs
// (create / edit / delete a node, session metadata) round-trip through silverwood —
// the delegation the server exists to do. Ground truth is re-read from silverwood, not
// server memory. Skip-mode only (no clone), so it runs in the sandbox.

import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { api, jsonInit } from "./helpers/app"; // stubs bun-pty, then loads the routes
import * as sw from "../server/services/silverwood";
import { newForest, cleanupForest, cli, SKIP_SOURCE } from "./helpers/forest";

function createNode(name: string, extra: Record<string, unknown> = {}) {
  return api(
    "/sessions",
    jsonInit("POST", {
      name,
      path: ["basic", "jj-colocated"],
      args: [SKIP_SOURCE],
      ...extra,
    }),
  );
}

async function nodes(): Promise<any[]> {
  const { body } = await api("/state");
  return body.nodes;
}

describe("papyrus routes → silverwood (in-process, skip-mode)", () => {
  let dir: string;
  beforeEach(() => {
    dir = newForest();
  });
  afterEach(() => cleanupForest(dir));

  test("GET /config echoes the active forest", async () => {
    const { status, body } = await api("/config");
    expect(status).toBe(200);
    expect(body.forest).toBe(dir);
  });

  test("GET /agents and GET /new-schema (delegates to silverwood)", async () => {
    const agents = await api("/agents");
    expect(agents.body[0].id).toBe("claude");
    const schema = await api("/new-schema");
    expect(schema.status).toBe(200);
    expect(schema.body.name).toBe("new");
  });

  test("empty forest → no nodes", async () => {
    expect(await nodes()).toEqual([]);
    expect((await api("/sessions")).body).toEqual([]);
  });

  test("create node registers a workstream and stores its position", async () => {
    const { status, body } = await createNode("web", { position: { x: 10, y: 20 } });
    expect(status).toBe(200);
    expect(body.checkoutState).toBe("initialized-without-checkout");

    const ns = await nodes();
    expect(ns).toHaveLength(1);
    expect(ns[0].customName).toBe("web");
    expect(ns[0].position).toEqual({ x: 10, y: 20 });
    // Ground truth: it's a real workstream in silverwood.
    expect((cli(["ls"]).json as any[]).length).toBe(1);
  });

  // A checkout-less `local-blank` node: the route creates it with no checkout mode and
  // skips the basic-only background `checkout` (which would error on a non-basic kind).
  test("create a local-blank node (no checkout, no background provisioning)", async () => {
    const { status, body } = await api(
      "/sessions",
      jsonInit("POST", { name: "blank", path: ["local-blank"], args: [] }),
    );
    expect(status).toBe(200);
    expect(body.checkoutState).toBe("none");

    const ns = await nodes();
    expect(ns).toHaveLength(1);
    // Ground truth: a real local-blank workstream in silverwood.
    expect(cli(["workstream", body.nodeId, "show"]).json.kind).toBe("local-blank");
  });

  test("edit node: name/color/notes/position round-trip through silverwood", async () => {
    const { body } = await createNode("orig");
    const id = body.nodeId;

    const res = await api(
      `/sessions/${id}`,
      jsonInit("PATCH", {
        customName: "renamed",
        customColor: "#123456",
        notes: "some notes",
        position: { x: 3, y: 4 },
      }),
    );
    expect(res.status).toBe(200);

    const node = (await nodes())[0];
    expect(node.customName).toBe("renamed");
    expect(node.customColor).toBe("#123456");
    expect(node.notes).toBe("some notes");
    expect(node.position).toEqual({ x: 3, y: 4 });
    // Ground truth: the durable name lives in silverwood.
    expect(cli(["workstream", id, "show"]).json.name).toBe("renamed");
  });

  test("delete node archives the workstream", async () => {
    const { body } = await createNode("temp");
    const id = body.nodeId;

    const res = await api(`/sessions/${id}`, { method: "DELETE" });
    expect(res.status).toBe(200);

    expect(await nodes()).toEqual([]); // hidden from the active canvas
    const all = cli(["ls", "--all"]).json as Array<{ id: string; status: string }>;
    expect(all.find((w) => w.id === id)?.status).toBe("archived");
  });

  test("session metadata: a seeded tab renames and removes via routes", async () => {
    const { body } = await createNode("with-session");
    const id = body.nodeId;
    const sid = crypto.randomUUID();
    // Seed a durable session record directly (no PTY needed to test its metadata).
    await sw.sessionCreate("plain-shell", id, sid, "shell");

    const tab = (n: any[]) => n[0].sessions.find((t: any) => t.sessionId === sid);
    expect(tab(await nodes())?.name).toBe("shell");

    const r1 = await api(`/sessions/${id}/sessions/${sid}`, jsonInit("PATCH", { name: "renamed-tab" }));
    expect(r1.status).toBe(200);
    expect(tab(await nodes())?.name).toBe("renamed-tab");

    const r2 = await api(`/sessions/${id}/sessions/${sid}`, { method: "DELETE" });
    expect(r2.status).toBe(200);
    expect(tab(await nodes())).toBeUndefined();
  });

  test("mutating an absent workstream surfaces silverwood's error as 400", async () => {
    const res = await api(`/sessions/not-a-uuid`, jsonInit("PATCH", { customName: "x" }));
    expect(res.status).toBe(400);
    expect(res.body.error).toBeTruthy();
  });
});
