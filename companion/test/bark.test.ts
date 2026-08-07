import { describe, expect, test } from "bun:test";
import {
  BarkNotifier,
  classifyTurnEnd,
  DISABLED_BARK,
  type BarkConfig,
} from "../src/bark";
import { RpcError } from "../src/rpc";

function barkConfig(overrides: Partial<BarkConfig> = {}): BarkConfig {
  return {
    deviceKey: "abc123",
    url: "https://api.day.app/",
    notifyOnApproval: true,
    notifyOnSessionEnd: true,
    ...overrides,
  };
}

function makeSpy(): { sent: string[]; sender: (url: string) => Promise<unknown> } {
  const sent: string[] = [];
  return {
    sent,
    sender: async (url: string) => {
      sent.push(url);
      return { ok: true };
    },
  };
}

describe("classifyTurnEnd", () => {
  test("end_turn is success", () => {
    expect(classifyTurnEnd({ stopReason: "end_turn" }, undefined)).toEqual({ kind: "success" });
  });

  test("cancelled produces no notification", () => {
    expect(classifyTurnEnd({ stopReason: "cancelled" }, undefined)).toEqual({ kind: "none" });
  });

  test("max_tokens and refusal are failures with the stop reason as detail", () => {
    expect(classifyTurnEnd({ stopReason: "max_tokens" }, undefined)).toEqual({
      kind: "failure",
      detail: "stopReason: max_tokens",
    });
    expect(classifyTurnEnd({ stopReason: "refusal" }, undefined)).toEqual({
      kind: "failure",
      detail: "stopReason: refusal",
    });
  });

  test("an unknown stop reason is treated as failure, not success", () => {
    expect(classifyTurnEnd({ stopReason: "something_new" }, undefined)).toEqual({
      kind: "failure",
      detail: "stopReason: something_new",
    });
  });

  test("a rejected request is a failure with the error message", () => {
    expect(classifyTurnEnd(undefined, new RpcError(-32000, "provider auth failed"))).toEqual({
      kind: "failure",
      detail: "provider auth failed",
    });
  });

  test("a result without a stop reason produces no notification", () => {
    expect(classifyTurnEnd({}, undefined)).toEqual({ kind: "none" });
    expect(classifyTurnEnd(undefined, undefined)).toEqual({ kind: "none" });
    expect(classifyTurnEnd(null, undefined)).toEqual({ kind: "none" });
  });
});

describe("BarkNotifier", () => {
  test("is disabled when the device key is empty", async () => {
    const spy = makeSpy();
    const notifier = new BarkNotifier(DISABLED_BARK, { sender: spy.sender });
    await notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t1", title: "run" });
    await notifier.notifySessionEnded({ id: "s1", cwd: "/p" }, { kind: "success" });
    await notifier.notifySessionEnded({ id: "s1", cwd: "/p" }, { kind: "failure", detail: "boom" });
    expect(spy.sent).toEqual([]);
  });

  test("sends an approval push with session/project identifiers, group and level", async () => {
    const spy = makeSpy();
    const notifier = new BarkNotifier(barkConfig(), { sender: spy.sender });
    await notifier.notifyApproval(
      { id: "sess_1", cwd: "/Users/x/demo" },
      { toolCallId: "call_1", title: "curl -s example.com" },
    );
    expect(spy.sent).toHaveLength(1);
    const decoded = decodeURIComponent(spy.sent[0]!);
    expect(decoded).toContain("https://api.day.app/abc123/");
    expect(decoded).toContain("需要审批 · demo");
    expect(decoded).toContain("curl -s example.com");
    expect(decoded).toContain("sess_1");
    expect(decoded).toContain("group=approval:sess_1");
    expect(decoded).toContain("level=timeSensitive");
  });

  test("URL-encodes the device key, title and body", async () => {
    const spy = makeSpy();
    const notifier = new BarkNotifier(barkConfig(), { sender: spy.sender });
    await notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t1", title: "a b/c" });
    expect(spy.sent[0]).toContain(encodeURIComponent("需要审批"));
    expect(spy.sent[0]).toContain(encodeURIComponent("a b/c"));
  });

  test("does not push the same approval request twice", async () => {
    const spy = makeSpy();
    const notifier = new BarkNotifier(barkConfig(), { sender: spy.sender });
    await notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t1", title: "run" });
    await notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t1", title: "run" });
    expect(spy.sent).toHaveLength(1);
  });

  test("a different approval request in the same session still pushes", async () => {
    const spy = makeSpy();
    const notifier = new BarkNotifier(barkConfig(), { sender: spy.sender });
    await notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t1", title: "a" });
    await notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t2", title: "b" });
    expect(spy.sent).toHaveLength(2);
  });

  test("resolveApproval lets the same request push again once resolved", async () => {
    const spy = makeSpy();
    const notifier = new BarkNotifier(barkConfig(), { sender: spy.sender });
    await notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t1", title: "run" });
    notifier.resolveApproval("s1", "t1");
    await notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t1", title: "run" });
    expect(spy.sent).toHaveLength(2);
  });

  test("clearSession forgets every pending approval of a session", async () => {
    const spy = makeSpy();
    const notifier = new BarkNotifier(barkConfig(), { sender: spy.sender });
    await notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t1", title: "a" });
    await notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t2", title: "b" });
    notifier.clearSession("s1");
    await notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t1", title: "a" });
    expect(spy.sent).toHaveLength(3);
  });

  test("notifyOnApproval off suppresses approval pushes but not session end", async () => {
    const spy = makeSpy();
    const notifier = new BarkNotifier(
      barkConfig({ notifyOnApproval: false }),
      { sender: spy.sender },
    );
    await notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t1", title: "run" });
    await notifier.notifySessionEnded({ id: "s1", cwd: "/p" }, { kind: "success" });
    expect(spy.sent).toHaveLength(1);
    expect(decodeURIComponent(spy.sent[0]!)).toContain("会话完成");
  });

  test("notifyOnSessionEnd off suppresses session end pushes but not approval", async () => {
    const spy = makeSpy();
    const notifier = new BarkNotifier(
      barkConfig({ notifyOnSessionEnd: false }),
      { sender: spy.sender },
    );
    await notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t1", title: "run" });
    await notifier.notifySessionEnded({ id: "s1", cwd: "/p" }, { kind: "success" });
    await notifier.notifySessionEnded({ id: "s1", cwd: "/p" }, { kind: "failure", detail: "boom" });
    expect(spy.sent).toHaveLength(1);
    expect(decodeURIComponent(spy.sent[0]!)).toContain("需要审批");
  });

  test("success and failure pushes are distinguishable and carry the project", async () => {
    const spy = makeSpy();
    const notifier = new BarkNotifier(barkConfig(), { sender: spy.sender });
    await notifier.notifySessionEnded({ id: "s1", cwd: "/proj/demo" }, { kind: "success" });
    await notifier.notifySessionEnded(
      { id: "s1", cwd: "/proj/demo" },
      { kind: "failure", detail: "provider auth failed" },
    );
    expect(spy.sent).toHaveLength(2);
    expect(decodeURIComponent(spy.sent[0]!)).toContain("会话完成 · demo");
    expect(decodeURIComponent(spy.sent[0]!)).toContain("group=sessionEnd:s1");
    expect(decodeURIComponent(spy.sent[1]!)).toContain("会话失败 · demo");
    expect(decodeURIComponent(spy.sent[1]!)).toContain("provider auth failed");
  });

  test("omits the project suffix when the session has no cwd", async () => {
    const spy = makeSpy();
    const notifier = new BarkNotifier(barkConfig(), { sender: spy.sender });
    await notifier.notifySessionEnded({ id: "s1" }, { kind: "success" });
    expect(decodeURIComponent(spy.sent[0]!)).toContain("会话完成");
    expect(decodeURIComponent(spy.sent[0]!)).not.toContain(" · ");
  });

  test("truncates overlong titles and bodies", async () => {
    const spy = makeSpy();
    const notifier = new BarkNotifier(barkConfig(), { sender: spy.sender });
    const longTitle = "t".repeat(500);
    const longBody = "b".repeat(500);
    await notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t1", title: longTitle });
    await notifier.notifySessionEnded({ id: "s1", cwd: "/p" }, { kind: "failure", detail: longBody });
    expect(spy.sent).toHaveLength(2);

    // URL shape: {base}/{key}/{title}/{body}?group=… — the fixed title stays
    // short; the long tool title / failure detail land in the body and are
    // truncated so the URL stays bounded.
    const titleSegment = decodeURIComponent(spy.sent[0]!.split("/").at(-2)!);
    const bodySegment = decodeURIComponent(spy.sent[1]!.split("/").at(-1)!.split("?")[0]!);
    expect(titleSegment).toBe("需要审批 · p");
    expect(bodySegment).toContain("…");
    expect(bodySegment.length).toBeLessThan(300);
    expect(bodySegment).toContain("s1");
  });

  test("a failing sender is logged and does not throw", async () => {
    const logs: string[] = [];
    const notifier = new BarkNotifier(barkConfig(), {
      sender: async () => {
        throw new Error("network down");
      },
      log: (m) => logs.push(m),
    });
    await expect(
      notifier.notifyApproval({ id: "s1", cwd: "/p" }, { toolCallId: "t1", title: "run" }),
    ).resolves.toBeUndefined();
    expect(logs[0]).toContain("network down");
  });
});
