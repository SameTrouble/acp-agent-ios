import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session";

function makeTmpDir(): string {
  return mkdtempSync(join(tmpdir(), "sess-test-"));
}

describe("SessionManager", () => {
  test("create adds a session with active status", () => {
    const dir = makeTmpDir();
    const sm = new SessionManager(join(dir, "s.json"));
    const s = sm.create("sess_1", "/proj/a");
    expect(s.id).toBe("sess_1");
    expect(s.cwd).toBe("/proj/a");
    expect(s.status).toBe("active");
    expect(s.hasPendingApproval).toBe(false);
    expect(typeof s.createdAt).toBe("number");
    expect(typeof s.lastActiveAt).toBe("number");
    rmSync(dir, { recursive: true });
  });

  test("list returns sessions sorted by lastActiveAt desc", () => {
    const dir = makeTmpDir();
    const sm = new SessionManager(join(dir, "s.json"));
    sm.create("sess_1", "/a");
    sm.create("sess_2", "/b");
    const list = sm.list();
    expect(list.length).toBe(2);
    expect(list[0]!.lastActiveAt).toBeGreaterThanOrEqual(list[1]!.lastActiveAt);
    rmSync(dir, { recursive: true });
  });

  test("get returns a session by id", () => {
    const dir = makeTmpDir();
    const sm = new SessionManager(join(dir, "s.json"));
    sm.create("sess_1", "/a");
    expect(sm.get("sess_1")?.cwd).toBe("/a");
    expect(sm.get("sess_none")).toBeUndefined();
    rmSync(dir, { recursive: true });
  });

  test("markEnded changes status to ended", () => {
    const dir = makeTmpDir();
    const sm = new SessionManager(join(dir, "s.json"));
    sm.create("sess_1", "/a");
    sm.markEnded("sess_1");
    expect(sm.get("sess_1")?.status).toBe("ended");
    rmSync(dir, { recursive: true });
  });

  test("markAllActiveInterrupted marks active sessions as interrupted", () => {
    const dir = makeTmpDir();
    const sm = new SessionManager(join(dir, "s.json"));
    sm.create("sess_1", "/a");
    sm.create("sess_2", "/b");
    sm.markEnded("sess_2");
    sm.markAllActiveInterrupted();
    expect(sm.get("sess_1")?.status).toBe("interrupted");
    expect(sm.get("sess_2")?.status).toBe("ended");
    rmSync(dir, { recursive: true });
  });

  test("setPendingApproval updates the flag", () => {
    const dir = makeTmpDir();
    const sm = new SessionManager(join(dir, "s.json"));
    sm.create("sess_1", "/a");
    sm.setPendingApproval("sess_1", true);
    expect(sm.get("sess_1")?.hasPendingApproval).toBe(true);
    sm.setPendingApproval("sess_1", false);
    expect(sm.get("sess_1")?.hasPendingApproval).toBe(false);
    rmSync(dir, { recursive: true });
  });

  test("persistence: sessions survive across manager instances", () => {
    const dir = makeTmpDir();
    const path = join(dir, "s.json");
    const sm1 = new SessionManager(path);
    sm1.create("sess_1", "/proj/foo");
    sm1.create("sess_2", "/proj/bar");
    sm1.markEnded("sess_2");

    const sm2 = new SessionManager(path);
    sm2.load();
    const list = sm2.list();
    expect(list.length).toBe(2);
    const s1 = list.find((s) => s.id === "sess_1");
    const s2 = list.find((s) => s.id === "sess_2");
    expect(s1?.cwd).toBe("/proj/foo");
    expect(s1?.status).toBe("interrupted");
    expect(s2?.status).toBe("ended");
    rmSync(dir, { recursive: true });
  });

  test("load handles missing file gracefully", () => {
    const dir = makeTmpDir();
    const sm = new SessionManager(join(dir, "nope.json"));
    sm.load();
    expect(sm.list()).toEqual([]);
    rmSync(dir, { recursive: true });
  });

  test("load handles malformed JSON gracefully", () => {
    const dir = makeTmpDir();
    const path = join(dir, "bad.json");
    writeFileSync(path, "not json{{{");
    const sm = new SessionManager(path);
    sm.load();
    expect(sm.list()).toEqual([]);
    rmSync(dir, { recursive: true });
  });

  test("touch updates lastActiveAt", () => {
    const dir = makeTmpDir();
    const sm = new SessionManager(join(dir, "s.json"));
    sm.create("sess_1", "/a");
    const before = sm.get("sess_1")!.lastActiveAt;
    sm.touch("sess_1");
    expect(sm.get("sess_1")!.lastActiveAt).toBeGreaterThanOrEqual(before);
    rmSync(dir, { recursive: true });
  });

  test("handleNotification updates lastActiveAt for a known session", () => {
    const dir = makeTmpDir();
    const sm = new SessionManager(join(dir, "s.json"));
    sm.create("sess_1", "/a");
    const before = sm.get("sess_1")!.lastActiveAt;
    sm.handleNotification("session/update", {
      sessionId: "sess_1",
      update: { sessionUpdate: "agent_message_chunk" },
    });
    expect(sm.get("sess_1")!.lastActiveAt).toBeGreaterThanOrEqual(before);
    rmSync(dir, { recursive: true });
  });

  test("handleNotification ignores unknown sessions and other methods", () => {
    const dir = makeTmpDir();
    const sm = new SessionManager(join(dir, "s.json"));
    sm.create("sess_1", "/a");
    sm.handleNotification("session/update", { sessionId: "sess_unknown", update: {} });
    sm.handleNotification("other/method", { sessionId: "sess_1" });
    expect(sm.list().length).toBe(1);
    rmSync(dir, { recursive: true });
  });
});
