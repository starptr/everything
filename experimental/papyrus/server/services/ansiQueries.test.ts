// UNIT test for the reconnect scrollback sanitizer. Not part of the nix-gated client suite
// (that derivation builds ./client only); run locally with `bun test server/services`.
import { describe, test, expect } from "bun:test";
import { stripQueries } from "./ansiQueries";

describe("stripQueries", () => {
  test("removes the DA1 device-attributes query", () => {
    expect(stripQueries("a\x1b[cb")).toBe("ab");
    expect(stripQueries("a\x1b[0cb")).toBe("ab");
  });

  test("removes DA2/DA3 queries", () => {
    expect(stripQueries("\x1b[>c")).toBe("");
    expect(stripQueries("\x1b[>0;95;0c")).toBe("");
    expect(stripQueries("\x1b[=c")).toBe("");
  });

  test("removes DSR status and cursor-position reports/requests", () => {
    expect(stripQueries("\x1b[5n")).toBe("");
    expect(stripQueries("\x1b[6n")).toBe("");
    expect(stripQueries("\x1b[?6n")).toBe("");
  });

  test("removes OSC color queries (the ? form) with BEL or ST terminator", () => {
    expect(stripQueries("\x1b]11;?\x07")).toBe("");
    expect(stripQueries("\x1b]10;?\x1b\\")).toBe("");
  });

  test("removes DECRQM and XTVERSION queries", () => {
    expect(stripQueries("\x1b[?2026$p")).toBe("");
    expect(stripQueries("\x1b[>0q")).toBe("");
  });

  test("leaves normal output, SGR, cursor motion, and OSC color SETS untouched", () => {
    expect(stripQueries("hello world\n")).toBe("hello world\n");
    expect(stripQueries("\x1b[31mred\x1b[0m")).toBe("\x1b[31mred\x1b[0m");
    expect(stripQueries("\x1b[10;20H")).toBe("\x1b[10;20H");
    // An OSC 11 *set* (no `?`) must survive — only the `?` query form is stripped.
    expect(stripQueries("\x1b]11;rgb:fafa/fafa/fafa\x07")).toBe(
      "\x1b]11;rgb:fafa/fafa/fafa\x07",
    );
  });

  test("strips the exact garbage-causing pair while keeping surrounding output", () => {
    const input = "prompt$ \x1b]11;?\x07\x1b[c done";
    expect(stripQueries(input)).toBe("prompt$  done");
  });
});
