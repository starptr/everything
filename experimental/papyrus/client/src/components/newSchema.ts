// The `new` command tree (mirrors `silverwood new-schema`, served at /api/new-schema).
// `new` is a tree of nested subcommands; each complete path (leaf) declares its own
// positional args. There is NO fixed variant/mode/seed shape — a node may have
// children, positionals, or both — so the modal renders inputs by walking this tree.

export interface ArgInfo {
  value_name: string;
  help: string;
  required: boolean;
}

export interface CommandNode {
  name: string; // subcommand name (kebab), or "new" at the root
  description: string;
  args: ArgInfo[]; // this node's own positionals, in order
  subcommands: CommandNode[]; // empty at a leaf
}

// Shown until GET /api/new-schema responds (and if it fails): the one variant/mode
// that has always existed, so the modal is usable before the fetch lands.
export const FALLBACK_SCHEMA: CommandNode = {
  name: "new",
  description: "",
  args: [],
  subcommands: [
    {
      name: "basic",
      description: "A basic workstream, materialized by a checkout mode.",
      args: [],
      subcommands: [
        {
          name: "jj-colocated",
          description: "jj/git colocated clone.",
          args: [
            {
              value_name: "SOURCE_HTTPS_URL",
              help: "HTTPS git endpoint to clone from.",
              required: true,
            },
          ],
          subcommands: [],
        },
      ],
    },
  ],
};

// A single rendered row: a subcommand dropdown, or a positional input.
export type Item =
  | { kind: "select"; depth: number; node: CommandNode; selected: string }
  | { kind: "input"; key: string; arg: ArgInfo };

// The first-child descent from a node down to a leaf — the default selection path
// (a list of chosen subcommand names, one per level).
export function defaultDescent(node: CommandNode): string[] {
  const names: string[] = [];
  let n = node;
  while (n.subcommands.length > 0) {
    n = n.subcommands[0];
    names.push(n.name);
  }
  return names;
}

// Follow chosen subcommand names from the root; null if the path doesn't resolve.
export function nodeAtPath(root: CommandNode, path: string[]): CommandNode | null {
  let n = root;
  for (const name of path) {
    const child = n.subcommands.find((s) => s.name === name);
    if (!child) return null;
    n = child;
  }
  return n;
}

// Walk root→leaf along `path`, collecting each node's dropdown (if it has children)
// and positional inputs (its args) in render order. A missing/invalid selection at a
// level defaults to that node's first child.
export function walk(schema: CommandNode, path: string[]): Item[] {
  const items: Item[] = [];
  let current: CommandNode | undefined = schema;
  let depth = 0;
  while (current) {
    const node: CommandNode = current;
    node.args.forEach((arg, i) => items.push({ kind: "input", key: `${depth}.${i}`, arg }));
    if (node.subcommands.length === 0) break;
    const selected: string = path[depth] ?? node.subcommands[0].name;
    items.push({ kind: "select", depth, node, selected });
    current = node.subcommands.find((s) => s.name === selected);
    depth++;
  }
  return items;
}
