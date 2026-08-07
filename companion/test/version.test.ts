import { describe, expect, test } from "bun:test";
import { isVersionRequest, versionLine } from "../src/version";
import { readFileSync } from "node:fs";
import { join } from "node:path";

describe("isVersionRequest", () => {
  test("matches --version and -v as the first argument", () => {
    expect(isVersionRequest(["--version"])).toBe(true);
    expect(isVersionRequest(["-v"])).toBe(true);
  });

  test("does not match other args or a config path first", () => {
    expect(isVersionRequest([])).toBe(false);
    expect(isVersionRequest(["/etc/companion.json"])).toBe(false);
    expect(isVersionRequest(["start", "--version"])).toBe(false);
  });
});

describe("versionLine", () => {
  test("reports the package.json version (no drift)", () => {
    const pkg = JSON.parse(readFileSync(join(__dirname, "..", "package.json"), "utf8"));
    expect(versionLine()).toBe(`acp-agent-companion ${pkg.version}`);
  });
});
