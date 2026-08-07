import { describe, expect, test } from "bun:test";
import { defaultConfigPath, loadConfig, parseConfig } from "../src/config";
import { DEFAULT_BARK_URL } from "../src/bark";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("parseConfig", () => {
  test("parses a valid config", () => {
    const cfg = parseConfig({
      host: "127.0.0.1",
      port: 9000,
      tokens: ["alpha", "beta"],
      agent: { command: "opencode", args: ["acp"] },
    });
    expect(cfg.port).toBe(9000);
    expect(cfg.tokens).toEqual(["alpha", "beta"]);
    expect(cfg.agent.command).toBe("opencode");
  });

  test("applies defaults for missing port and agent", () => {
    const cfg = parseConfig({ tokens: ["t"] });
    expect(cfg.port).toBe(8787);
    expect(cfg.host).toBe("0.0.0.0");
    expect(cfg.agent.command).toBe("opencode");
    expect(cfg.agent.args).toEqual(["acp"]);
  });

  test("rejects missing tokens", () => {
    expect(() => parseConfig({ tokens: [] })).toThrow(/non-empty array of strings/);
    expect(() => parseConfig({})).toThrow(/array of strings/);
    expect(() => parseConfig({ tokens: "nope" })).toThrow(/array of strings/);
    expect(() => parseConfig({ tokens: ["ok", 42] })).toThrow(/only non-empty strings/);
  });

  test("rejects invalid port", () => {
    expect(() => parseConfig({ tokens: ["t"], port: 70000 })).toThrow(/port/);
    expect(() => parseConfig({ tokens: ["t"], port: "8787" })).toThrow(/port/);
  });

  test("rejects non-object config", () => {
    expect(() => parseConfig(null)).toThrow(/object/);
    expect(() => parseConfig("x")).toThrow(/object/);
  });
});

describe("parseConfig bark", () => {
  test("is absent when no bark section is given", () => {
    const cfg = parseConfig({ tokens: ["t"] });
    expect(cfg.bark).toBeUndefined();
  });

  test("parses a bark section with defaults", () => {
    const cfg = parseConfig({ tokens: ["t"], bark: { deviceKey: "key-1" } });
    expect(cfg.bark).toEqual({
      deviceKey: "key-1",
      url: DEFAULT_BARK_URL,
      notifyOnApproval: true,
      notifyOnSessionEnd: true,
    });
  });

  test("honours url override and per-trigger switches", () => {
    const cfg = parseConfig({
      tokens: ["t"],
      bark: { deviceKey: "key-1", url: "https://bark.example.com", notifyOnApproval: false, notifyOnSessionEnd: false },
    });
    expect(cfg.bark).toEqual({
      deviceKey: "key-1",
      url: "https://bark.example.com",
      notifyOnApproval: false,
      notifyOnSessionEnd: false,
    });
  });

  test("an empty device key disables bark entirely", () => {
    const cfg = parseConfig({ tokens: ["t"], bark: { deviceKey: "" } });
    expect(cfg.bark).toBeUndefined();
  });

  test("rejects an invalid bark section", () => {
    expect(() => parseConfig({ tokens: ["t"], bark: "nope" })).toThrow(/bark/);
    expect(() => parseConfig({ tokens: ["t"], bark: { deviceKey: 42 } })).toThrow(/deviceKey/);
    expect(() => parseConfig({ tokens: ["t"], bark: { deviceKey: "k", url: 42 } })).toThrow(/bark\.url/);
    expect(() => parseConfig({ tokens: ["t"], bark: { deviceKey: "k", notifyOnApproval: "yes" } })).toThrow(/notifyOnApproval/);
    expect(() => parseConfig({ tokens: ["t"], bark: { deviceKey: "k", notifyOnSessionEnd: 1 } })).toThrow(/notifyOnSessionEnd/);
  });
});

describe("defaultConfigPath", () => {
  test("uses XDG_CONFIG_HOME when set", () => {
    expect(defaultConfigPath({ HOME: "/home/u", XDG_CONFIG_HOME: "/xdg" })).toBe(
      "/xdg/acp-agent/companion.json",
    );
  });

  test("falls back to ~/.config", () => {
    expect(defaultConfigPath({ HOME: "/home/u" })).toBe("/home/u/.config/acp-agent/companion.json");
  });
});

describe("loadConfig", () => {
  test("reads and parses a file", () => {
    const dir = mkdtempSync(join(tmpdir(), "companion-"));
    const file = join(dir, "companion.json");
    writeFileSync(file, JSON.stringify({ tokens: ["t"], port: 1234 }));
    const cfg = loadConfig(file);
    expect(cfg.tokens).toEqual(["t"]);
    expect(cfg.port).toBe(1234);
  });

  test("throws a clear error when the file is missing", () => {
    expect(() => loadConfig(join(tmpdir(), "does-not-exist.json"))).toThrow(/not found/);
  });
});