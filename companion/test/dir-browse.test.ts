import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { browseDir, DirBrowseError } from "../src/dir-browse";

function setupTree(): string {
  const dir = mkdtempSync(join(tmpdir(), "browse-test-"));
  mkdirSync(join(dir, "alpha"));
  mkdirSync(join(dir, "Beta"));
  mkdirSync(join(dir, ".hidden"));
  mkdirSync(join(dir, "alpha", "nested"));
  writeFileSync(join(dir, "README.md"), "");
  writeFileSync(join(dir, "notes.txt"), "");
  return dir;
}

describe("browseDir", () => {
  test("lists subdirectories only, files excluded", () => {
    const dir = setupTree();
    const listing = browseDir(dir);
    expect(listing.path).toBe(dir);
    expect(listing.entries.map((e) => e.name)).toEqual(["alpha", "Beta", ".hidden"].sort(byName));
    for (const entry of listing.entries) {
      expect(entry.path).toBe(join(dir, entry.name));
    }
  });

  test("entries are sorted case-insensitively", () => {
    const dir = setupTree();
    const listing = browseDir(dir);
    expect(listing.entries.map((e) => e.name)).toEqual(["alpha", "Beta", ".hidden"].sort(byName));
    const names = listing.entries.map((e) => e.name.toLowerCase());
    expect(names).toEqual([...names].sort());
  });

  test("parent points one level up", () => {
    const dir = setupTree();
    const nested = join(dir, "alpha");
    const listing = browseDir(nested);
    expect(listing.parent).toBe(dir);
  });

  test("filesystem root has no parent", () => {
    const listing = browseDir("/");
    expect(listing.parent).toBeNull();
    expect(listing.path).toBe("/");
  });

  test("hidden directories are included", () => {
    const dir = setupTree();
    const listing = browseDir(dir);
    expect(listing.entries.some((e) => e.name === ".hidden")).toBe(true);
  });

  test("relative paths are resolved against the cwd", () => {
    const listing = browseDir(".");
    expect(listing.path).toBe(process.cwd());
  });

  test("throws DirBrowseError for a missing path", () => {
    expect(() => browseDir("/nonexistent/browse-path-xyz")).toThrow(DirBrowseError);
  });

  test("throws DirBrowseError when the path is a file", () => {
    const dir = setupTree();
    expect(() => browseDir(join(dir, "README.md"))).toThrow(DirBrowseError);
  });

  test("empty directory yields an empty entry list", () => {
    const dir = mkdtempSync(join(tmpdir(), "browse-empty-"));
    const listing = browseDir(dir);
    expect(listing.entries).toEqual([]);
    expect(listing.parent).toBe(tmpdir());
  });
});

describe("browseDir default path", () => {
  test("defaults to HOME when no path is given", () => {
    const listing = browseDir(undefined, { HOME: "/" });
    expect(listing.path).toBe("/");
  });

  test("falls back to root when HOME is missing", () => {
    const listing = browseDir(undefined, {});
    expect(listing.path).toBe("/");
  });

  test("falls back to root when HOME does not exist", () => {
    const listing = browseDir(undefined, { HOME: "/nonexistent/home-xyz" });
    expect(listing.path).toBe("/");
  });
});

function byName(a: string, b: string): number {
  const la = a.toLowerCase();
  const lb = b.toLowerCase();
  return la < lb ? -1 : la > lb ? 1 : 0;
}
