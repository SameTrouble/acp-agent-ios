import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expandPrompt, isFileRefBlock } from "../src/prompt-expander";

function setupFixture(): string {
  const dir = mkdtempSync(join(tmpdir(), "expand-test-"));
  mkdirSync(join(dir, "src"), { recursive: true });
  writeFileSync(join(dir, "src/hello.ts"), "export const hello = 'world';\n");
  writeFileSync(join(dir, "README.md"), "# Test Project\nHello world.\n");
  writeFileSync(join(dir, "notes.txt"), "some notes\n");
  return dir;
}

describe("isFileRefBlock", () => {
  test("identifies file_ref blocks", () => {
    expect(isFileRefBlock({ type: "file_ref", path: "foo.ts" })).toBe(true);
  });
  test("rejects non-file_ref blocks", () => {
    expect(isFileRefBlock({ type: "text", text: "hi" })).toBe(false);
    expect(isFileRefBlock(null)).toBe(false);
    expect(isFileRefBlock("string")).toBe(false);
    expect(isFileRefBlock({ type: "file_ref" })).toBe(false);
    expect(isFileRefBlock({ path: "foo.ts" })).toBe(false);
  });
});

describe("expandPrompt with embeddedContext=true", () => {
  test("expands file_ref into resource block with content", async () => {
    const dir = setupFixture();
    const prompt = [{ type: "file_ref", path: "src/hello.ts" }];
    const result = await expandPrompt(prompt, dir, true);
    expect(result.length).toBe(1);
    const block = result[0] as { type: string; resource: { uri: string; text: string; mimeType: string } };
    expect(block.type).toBe("resource");
    expect(block.resource.uri).toEndWith("/src/hello.ts");
    expect(block.resource.text).toBe("export const hello = 'world';\n");
    expect(block.resource.mimeType).toBe("text/typescript");
  });

  test("preserves text blocks unchanged", async () => {
    const dir = setupFixture();
    const prompt = [{ type: "text", text: "explain this code" }];
    const result = await expandPrompt(prompt, dir, true);
    expect(result).toEqual([{ type: "text", text: "explain this code" }]);
  });

  test("interleaves text and file references", async () => {
    const dir = setupFixture();
    const prompt = [
      { type: "text", text: "look at this file:" },
      { type: "file_ref", path: "README.md" },
      { type: "text", text: "and also this:" },
      { type: "file_ref", path: "notes.txt" },
    ];
    const result = await expandPrompt(prompt, dir, true);
    expect(result.length).toBe(4);
    expect((result[0] as { type: string }).type).toBe("text");
    expect((result[1] as { type: string }).type).toBe("resource");
    expect((result[2] as { type: string }).type).toBe("text");
    expect((result[3] as { type: string }).type).toBe("resource");
  });

  test("multiple file references all expand", async () => {
    const dir = setupFixture();
    const prompt = [
      { type: "file_ref", path: "src/hello.ts" },
      { type: "file_ref", path: "README.md" },
    ];
    const result = await expandPrompt(prompt, dir, true);
    expect(result.length).toBe(2);
    expect((result[0] as { type: string }).type).toBe("resource");
    expect((result[1] as { type: string }).type).toBe("resource");
  });

  test("missing file falls back to resource_link", async () => {
    const dir = setupFixture();
    const prompt = [{ type: "file_ref", path: "nonexistent.ts" }];
    const result = await expandPrompt(prompt, dir, true);
    expect(result.length).toBe(1);
    expect((result[0] as { type: string }).type).toBe("resource_link");
  });

  test("a path escaping the session cwd is linked, never read", async () => {
    const dir = setupFixture();
    const prompt = [{ type: "file_ref", path: "../../../etc/passwd" }];
    const result = await expandPrompt(prompt, dir, true);
    expect(result.length).toBe(1);
    const block = result[0] as { type: string; resource?: unknown };
    expect(block.type).toBe("resource_link");
    expect(block.resource).toBeUndefined();
  });

  test("an absolute path outside the session cwd is linked, never read", async () => {
    const dir = setupFixture();
    const prompt = [{ type: "file_ref", path: "/etc/hosts" }];
    const result = await expandPrompt(prompt, dir, true);
    const block = result[0] as { type: string; resource?: unknown };
    expect(block.type).toBe("resource_link");
    expect(block.resource).toBeUndefined();
  });

  test("resource uri uses absolute file:// path", async () => {
    const dir = setupFixture();
    const prompt = [{ type: "file_ref", path: "README.md" }];
    const result = await expandPrompt(prompt, dir, true);
    const block = result[0] as { resource: { uri: string } };
    expect(block.resource.uri).toMatch(/^file:\/\/\/.*README\.md$/);
  });
});

describe("expandPrompt with embeddedContext=false", () => {
  test("expands file_ref into resource_link block", async () => {
    const dir = setupFixture();
    const prompt = [{ type: "file_ref", path: "src/hello.ts" }];
    const result = await expandPrompt(prompt, dir, false);
    expect(result.length).toBe(1);
    const block = result[0] as { type: string; uri: string; name: string; size: number; mimeType: string };
    expect(block.type).toBe("resource_link");
    expect(block.uri).toEndWith("/src/hello.ts");
    expect(block.name).toBe("hello.ts");
    expect(typeof block.size).toBe("number");
    expect(block.size).toBeGreaterThan(0);
    expect(block.mimeType).toBe("text/typescript");
  });

  test("interleaves text and resource_link blocks", async () => {
    const dir = setupFixture();
    const prompt = [
      { type: "text", text: "see this file" },
      { type: "file_ref", path: "README.md" },
    ];
    const result = await expandPrompt(prompt, dir, false);
    expect(result.length).toBe(2);
    expect((result[0] as { type: string }).type).toBe("text");
    expect((result[1] as { type: string }).type).toBe("resource_link");
  });

  test("missing file still produces resource_link", async () => {
    const dir = setupFixture();
    const prompt = [{ type: "file_ref", path: "missing.txt" }];
    const result = await expandPrompt(prompt, dir, false);
    expect(result.length).toBe(1);
    expect((result[0] as { type: string }).type).toBe("resource_link");
    expect((result[0] as { name: string }).name).toBe("missing.txt");
  });
});
