import { describe, test, expect } from "bun:test";
import { terminalWsUrl } from "./terminalWs";

const loc = (over: Partial<{ protocol: string; hostname: string; host: string }> = {}) => ({
  protocol: "http:",
  hostname: "localhost",
  host: "localhost:6969",
  ...over,
});

describe("terminalWsUrl", () => {
  test("known backend port → connects directly to it (bypasses the page origin)", () => {
    expect(terminalWsUrl(loc({ host: "localhost:6969" }), 7968, "sid-1")).toBe(
      "ws://localhost:7968/ws?sessionId=sid-1",
    );
  });

  test("null port → falls back to the page origin (prod = same port)", () => {
    expect(terminalWsUrl(loc({ host: "localhost:6968" }), null, "sid-1")).toBe(
      "ws://localhost:6968/ws?sessionId=sid-1",
    );
  });

  test("https page → wss scheme", () => {
    expect(
      terminalWsUrl(loc({ protocol: "https:", hostname: "host", host: "host:443" }), 7968, "s"),
    ).toBe("wss://host:7968/ws?sessionId=s");
  });

  test("null port over https still uses the page host with wss", () => {
    expect(
      terminalWsUrl(loc({ protocol: "https:", hostname: "host", host: "host:443" }), null, "s"),
    ).toBe("wss://host:443/ws?sessionId=s");
  });
});
