// Server e2e harness: point silverwood at a throwaway forest per test, and run the
// real binary directly for seeding fixtures + asserting ground truth (independent of
// papyrus's own wrapper). The TS analog of silverwood's `tests/common/mod.rs`.

import { mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

// The same binary the server wrapper shells out to (`silverwood.ts` uses this env,
// defaulting to "silverwood"). Resolve a bare name via PATH so `cli()` and the
// wrapper agree; fail loudly if neither is available.
export const SILVERWOOD_BIN =
  process.env.SILVERWOOD_BIN || Bun.which("silverwood") || "";
if (!SILVERWOOD_BIN) {
  throw new Error(
    "papyrus server e2e tests need a silverwood binary: set SILVERWOOD_BIN or put `silverwood` on PATH",
  );
}

// A well-formed https source that never resolves (RFC 6761 `.invalid`), so the
// non-awaited background checkout the create route kicks off fails fast everywhere
// (and leaves no real clone) while `--checkout-extent skip` registration still works.
export const SKIP_SOURCE = "https://example.invalid/papyrus-e2e.git";

// Create a fresh forest and point every subsequent silverwood invocation at it (the
// server wrapper and `cli()` both read this env at spawn time). Call in `beforeEach`.
export function newForest(): string {
  const dir = mkdtempSync(join(tmpdir(), "papyrus-e2e-"));
  process.env.SILVERWOOD_FOREST_PATH = dir;
  return dir;
}

export function cleanupForest(dir: string): void {
  try {
    rmSync(dir, { recursive: true, force: true });
  } catch {
    // A detached background clone may still hold the dir; best-effort.
  }
}

export interface CliResult {
  status: number;
  stdout: string;
  stderr: string;
  json: any;
}

// Run `silverwood --json <args>` against the current forest and parse stdout — used
// to seed state and to assert ground truth straight from silverwood.
export function cli(args: string[]): CliResult {
  const proc = Bun.spawnSync([SILVERWOOD_BIN, "--json", ...args], {
    env: process.env,
  });
  const stdout = proc.stdout.toString();
  const stderr = proc.stderr.toString();
  const status = proc.exitCode ?? -1;
  let json: any = null;
  if (status === 0 && stdout.trim()) {
    try {
      json = JSON.parse(stdout);
    } catch {
      // leave json null; callers that need it assert on status first
    }
  }
  return { status, stdout, stderr, json };
}
