// The session kinds a tab can be created from (mirrors `silverwood session-schema`, served
// at /api/session-schema). One entry per `session create` subcommand; `options` are the
// user-supplied flags beyond the papyrus-minted id/session_id/name. silverwood is the single
// source of truth — the New Tab menu's titles (the kind tag) and descriptions (the kind's
// clap `about`) come straight from here; papyrus only decides the icon.

export interface SessionOptionInfo {
  long: string; // long flag without `--`, e.g. "run-direnv-exec"
  help: string;
  required: boolean;
  value_kind: "bool" | "string";
}

export interface SessionKindInfo {
  kind: string; // kebab kind tag, = the silverwood SessionKind tag
  description: string;
  options: SessionOptionInfo[];
}

// Shown until GET /api/session-schema responds (and if it fails): the kinds that exist
// today, so the menu is usable before the fetch lands. Descriptions are terse placeholders —
// the real ones arrive from silverwood on fetch.
export const FALLBACK_SESSION_SCHEMA: SessionKindInfo[] = [
  { kind: "claude-code", description: "A Claude Code session.", options: [] },
  { kind: "plain-shell", description: "A plain login shell.", options: [] },
  {
    kind: "claude-code-noninteractive",
    description: "A Claude Code session run non-interactively.",
    options: [
      {
        long: "run-direnv-exec",
        help: "Load the checkout's .envrc (direnv exec).",
        required: true,
        value_kind: "bool",
      },
    ],
  },
  { kind: "disk-space", description: "A disk-space monitor session.", options: [] },
];

// Icon per kind — the ONLY presentation papyrus owns (silverwood supplies the title +
// description). An unknown (future) kind still renders, with a generic terminal icon.
export interface KindPresentation {
  icon: string;
  color?: string;
}
const KIND_PRESENTATION: Record<string, KindPresentation> = {
  "claude-code": { icon: "sparkles", color: "#F97316" },
  "claude-code-noninteractive": { icon: "sparkles", color: "#F97316" },
  "plain-shell": { icon: "terminal" },
  "disk-space": { icon: "cpu" },
};
export function kindPresentation(kind: string): KindPresentation {
  return KIND_PRESENTATION[kind] ?? { icon: "terminal" };
}

// One rendered menu row: clicking it POSTs `{ kind, options }` to create the session. `label`
// is the silverwood kind tag (plus the chosen option flag for a sub-row); `description` is the
// kind's silverwood `about`. A `disabled` row is shown but not clickable.
export interface VariantRow {
  key: string;
  kind: string;
  options: Record<string, string>;
  label: string;
  description: string;
  icon: string;
  color?: string;
  disabled?: boolean;
}

// Expand one kind into the rows that create it (click = create immediately):
//  - no required options       → 1 row
//  - required bool option(s)   → the cartesian of true/false across them (1 today → 2 rows)
//  - a required non-bool option → 1 disabled row (a flat click can't supply free text)
// A sub-row's title appends `long=value` (the silverwood flag name) so the choice is explicit.
export function expandKindToRows(k: SessionKindInfo): VariantRow[] {
  const p = kindPresentation(k.kind);
  const required = k.options.filter((o) => o.required);
  const nonBool = required.find((o) => o.value_kind !== "bool");
  if (nonBool) {
    return [
      {
        key: k.kind,
        kind: k.kind,
        options: {},
        label: k.kind,
        description: `Needs --${nonBool.long}; not supported here`,
        icon: p.icon,
        color: p.color,
        disabled: true,
      },
    ];
  }
  if (required.length === 0) {
    return [
      {
        key: k.kind,
        kind: k.kind,
        options: {},
        label: k.kind,
        description: k.description,
        icon: p.icon,
        color: p.color,
      },
    ];
  }
  let combos: Array<Record<string, string>> = [{}];
  for (const o of required) {
    combos = combos.flatMap((c) => ["true", "false"].map((v) => ({ ...c, [o.long]: v })));
  }
  return combos.map((options) => {
    const flags = required.map((o) => `${o.long}=${options[o.long]}`);
    return {
      key: `${k.kind}:${flags.join(",")}`,
      kind: k.kind,
      options,
      label: `${k.kind} (${flags.join(", ")})`,
      description: k.description,
      icon: p.icon,
      color: p.color,
    };
  });
}

// All menu rows for a schema, in kind order (each kind expanded to its row(s)).
export const schemaToRows = (schema: SessionKindInfo[]): VariantRow[] =>
  schema.flatMap(expandKindToRows);
