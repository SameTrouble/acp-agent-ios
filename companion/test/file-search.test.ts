import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { searchFiles } from "../src/file-search";

function setupProject(): string {
  const dir = mkdtempSync(join(tmpdir(), "search-test-"));
  mkdirSync(join(dir, "src"), { recursive: true });
  mkdirSync(join(dir, "src/utils"), { recursive: true });
  mkdirSync(join(dir, "test"), { recursive: true });
  mkdirSync(join(dir, "node_modules/foo"), { recursive: true });
  mkdirSync(join(dir, ".git"), { recursive: true });
  writeFileSync(join(dir, "src/main.ts"), "");
  writeFileSync(join(dir, "src/utils/helpers.ts"), "");
  writeFileSync(join(dir, "src/server.ts"), "");
  writeFileSync(join(dir, "src/config.ts"), "");
  writeFileSync(join(dir, "test/server.test.ts"), "");
  writeFileSync(join(dir, "README.md"), "");
  writeFileSync(join(dir, "package.json"), "");
  writeFileSync(join(dir, "node_modules/foo/index.js"), "");
  writeFileSync(join(dir, ".git/HEAD"), "");
  return dir;
}

describe("searchFiles", () => {
  test("returns empty for non-existent directory", () => {
    const results = searchFiles("/nonexistent/path/xyz", "foo");
    expect(results).toEqual([]);
  });

  test("returns files when query is empty", () => {
    const dir = setupProject();
    const results = searchFiles(dir, "", 5);
    expect(results.length).toBe(5);
    for (const r of results) {
      expect(typeof r.path).toBe("string");
      expect(r.score).toBe(1);
    }
  });

  test("excludes node_modules and .git", () => {
    const dir = setupProject();
    const results = searchFiles(dir, "index");
    expect(results.some((r) => r.path.includes("node_modules"))).toBe(false);
    expect(results.some((r) => r.path.includes(".git"))).toBe(false);
  });

  test("fuzzy matches by substring", () => {
    const dir = setupProject();
    const results = searchFiles(dir, "server");
    expect(results.length).toBeGreaterThan(0);
    expect(results[0]!.path).toMatch(/server/);
  });

  test("ranks basename matches higher than path matches", () => {
    const dir = setupProject();
    const results = searchFiles(dir, "main");
    expect(results.length).toBeGreaterThan(0);
    const top = results[0]!;
    expect(top.path.endsWith("main.ts")).toBe(true);
  });

  test("ranks exact basename prefix match highest", () => {
    const dir = setupProject();
    const results = searchFiles(dir, "server.ts");
    expect(results.length).toBeGreaterThan(0);
    const top = results[0]!;
    expect(top.path.endsWith("src/server.ts") || top.path.endsWith("test/server.test.ts")).toBe(true);
  });

  test("supports subsequence fuzzy matching", () => {
    const dir = setupProject();
    const results = searchFiles(dir, "srv");
    expect(results.length).toBeGreaterThan(0);
    expect(results.some((r) => r.path.includes("server"))).toBe(true);
  });

  test("respects limit parameter", () => {
    const dir = setupProject();
    const results = searchFiles(dir, "", 3);
    expect(results.length).toBe(3);
  });

  test("returns files with relative paths", () => {
    const dir = setupProject();
    const results = searchFiles(dir, "README");
    expect(results.length).toBeGreaterThan(0);
    expect(results[0]!.path).toBe("README.md");
  });
});
