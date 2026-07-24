import { describe, test, expect } from "bun:test";
import {
  type CommandNode,
  type Item,
  FALLBACK_SCHEMA,
  defaultDescent,
  nodeAtPath,
  walk,
} from "./newSchema";

// A two-mode tree with distinct positional shapes, standing in for `new-schema`.
const SCHEMA: CommandNode = {
  name: "new",
  description: "",
  args: [],
  subcommands: [
    {
      name: "basic",
      description: "basic",
      args: [],
      subcommands: [
        {
          name: "jj-colocated",
          description: "jj",
          args: [{ value_name: "SOURCE_HTTPS_URL", help: "url", required: true }],
          subcommands: [],
        },
        {
          name: "apfs-cow",
          description: "apfs",
          args: [{ value_name: "ABSOLUTE_PATH", help: "path", required: true }],
          subcommands: [],
        },
      ],
    },
  ],
};

const selects = (items: Item[]) => items.filter((i) => i.kind === "select");
const inputs = (items: Item[]) =>
  items.filter((i): i is Extract<Item, { kind: "input" }> => i.kind === "input");

describe("newSchema tree helpers", () => {
  test("defaultDescent walks first children down to a leaf", () => {
    expect(defaultDescent(SCHEMA)).toEqual(["basic", "jj-colocated"]);
    expect(defaultDescent(FALLBACK_SCHEMA)).toEqual(["basic", "jj-colocated"]);
    // A leaf has no further descent.
    expect(defaultDescent(SCHEMA.subcommands[0].subcommands[1])).toEqual([]);
  });

  test("nodeAtPath resolves a path and rejects an unknown one", () => {
    expect(nodeAtPath(SCHEMA, ["basic", "apfs-cow"])?.name).toBe("apfs-cow");
    expect(nodeAtPath(SCHEMA, [])?.name).toBe("new");
    expect(nodeAtPath(SCHEMA, ["basic", "nope"])).toBeNull();
  });

  test("walk yields a dropdown per level then the chosen leaf's positional", () => {
    const items = walk(SCHEMA, ["basic", "jj-colocated"]);
    // Two dropdowns (variant, mode) at depths 0 and 1.
    expect(selects(items).map((s) => (s.kind === "select" ? s.depth : -1))).toEqual([0, 1]);
    // One positional input: the jj leaf's HTTPS url.
    const ins = inputs(items);
    expect(ins).toHaveLength(1);
    expect(ins[0].arg.value_name).toBe("SOURCE_HTTPS_URL");
    expect(ins[0].key).toBe("2.0");
  });

  test("walk swaps the positional when a different leaf is selected", () => {
    const ins = inputs(walk(SCHEMA, ["basic", "apfs-cow"]));
    expect(ins).toHaveLength(1);
    expect(ins[0].arg.value_name).toBe("ABSOLUTE_PATH");
  });

  test("walk defaults a missing/invalid selection to the first child", () => {
    // An empty path still surfaces both dropdowns, defaulted to first children,
    // and the default leaf's positional.
    const items = walk(SCHEMA, []);
    expect(selects(items).map((s) => (s.kind === "select" ? s.selected : ""))).toEqual([
      "basic",
      "jj-colocated",
    ]);
    expect(inputs(items)[0].arg.value_name).toBe("SOURCE_HTTPS_URL");
  });
});
