import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { AcpClient, type InitializeResult } from "../src/acp";
import type { AgentConfig, CompanionConfig } from "../src/config";
import { CompanionServer } from "../src/server";
import { SessionManager } from "../src/session";

const here = dirname(fileURLToPath(import.meta.url));
const mockAgentPath = join(here, "helpers", "mock-agent.ts");

const agentConfig: AgentConfig = { command: "bun", args: [mockAgentPath] };
const config: CompanionConfig = {
  host: "127.0.0.1",
  port: 0,
  tokens: ["good-token", "second-token"],
  agent: agentConfig,
  sessionStorePath: "",
  eventBufferCapacity: 100,
};

let server: CompanionServer;
let acp: AcpClient;
let baseUrl: string;
let sessions: SessionManager;
let tmpDir: string;

function connect(): WebSocket {
  return new WebSocket(baseUrl);
}

function send(ws: WebSocket, obj: unknown): void {
  ws.send(JSON.stringify(obj));
}

function waitOpen(ws: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    ws.onopen = () => resolve();
    ws.onerror = () => reject(new Error("ws error"));
  });
}

interface QueuedSocket {
  queue: unknown[];
  resolvers: Array<(msg: unknown) => void>;
}

function makeQueue(ws: WebSocket): QueuedSocket {
  const q: QueuedSocket = { queue: [], resolvers: [] };
  ws.addEventListener("message", (ev) => {
    const msg = JSON.parse(String(ev.data));
    const resolver = q.resolvers.shift();
    if (resolver) resolver(msg);
    else q.queue.push(msg);
  });
  return q;
}

function nextMessage(q: QueuedSocket): Promise<unknown> {
  const queued = q.queue.shift();
  if (queued !== undefined) return Promise.resolve(queued);
  return new Promise((resolve) => q.resolvers.push(resolve));
}

function collectMessages(q: QueuedSocket, count: number): Promise<unknown[]> {
  const msgs: unknown[] = [];
  const drain = async (): Promise<unknown[]> => {
    while (msgs.length < count) {
      msgs.push(await nextMessage(q));
    }
    return msgs;
  };
  return drain();
}

beforeAll(async () => {
  tmpDir = mkdtempSync(join(tmpdir(), "companion-test-"));
  sessions = new SessionManager(join(tmpDir, "sessions.json"));
  acp = AcpClient.spawn(agentConfig);
  const agentInfo = (await acp.initialize()) as InitializeResult;
  server = new CompanionServer({ config, acp, agentInfo, sessions });
  await server.listen();
  const url = server.url!;
  baseUrl = url.replace(/^http/, "ws");
});

afterAll(async () => {
  await server.stop();
  await acp.close();
});

describe("auth gate", () => {
  test("correct token authenticates", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    const msg = (await nextMessage(q)) as { result?: { ok: boolean }; id: number };
    expect(msg.result?.ok).toBe(true);
    expect(msg.id).toBe(1);
    ws.close();
  });

  test("wrong token is rejected and connection closes", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    const closePromise = new Promise<void>((resolve) => { ws.onclose = () => resolve(); });
    send(ws, { jsonrpc: "2.0", method: "auth", params: { token: "bad-token" } });
    const msg = (await nextMessage(q)) as { error?: { code: number }; id: number };
    expect(msg.error?.code).toBe(-32001);
    expect(msg.id).toBe(0);
    await closePromise;
  });

  test("methods before auth are rejected", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "session/new", params: { cwd: "/x" } });
    const msg = (await nextMessage(q)) as { error?: { code: number } };
    expect(msg.error?.code).toBe(-32001);
    ws.close();
  });
});

describe("session lifecycle passthrough", () => {
  test("initialize returns agent info locally", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);
    send(ws, { jsonrpc: "2.0", id: 2, method: "initialize" });
    const msg = (await nextMessage(q)) as { result?: { agentInfo?: { name: string }; authMethods: unknown[] }; id: number };
    expect(msg.result?.agentInfo?.name).toBe("mock-agent");
    expect(msg.result?.authMethods).toEqual([]);
    expect(msg.id).toBe(2);
    ws.close();
  });

  test("agent errors are passed through with their original code", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);
    send(ws, { jsonrpc: "2.0", id: 9, method: "does_not_exist" });
    const msg = (await nextMessage(q)) as { error?: { code: number }; id: number };
    expect(msg.error?.code).toBe(-32601);
    expect(msg.id).toBe(9);
    ws.close();
  });

  test("two clients both receive the same session/update stream", async () => {
    const authenticate = async () => {
      const ws = connect();
      await waitOpen(ws);
      const q = makeQueue(ws);
      send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
      await nextMessage(q);
      return { ws, q };
    };

    const { ws: wsA, q: qA } = await authenticate();
    const { ws: wsB, q: qB } = await authenticate();

    send(wsA, {
      jsonrpc: "2.0",
      id: 2,
      method: "session/new",
      params: { cwd: "/project" },
    });
    const newResult = (await nextMessage(qA)) as { result?: { sessionId: string } };
    const sessionId = newResult.result!.sessionId;

    send(wsA, {
      jsonrpc: "2.0",
      id: 3,
      method: "session/prompt",
      params: { sessionId, prompt: [{ type: "text", text: "hi" }] },
    });

    const [aMsgs, bMsgs] = await Promise.all([
      collectMessages(qA, 3),
      collectMessages(qB, 2),
    ]);

    const aUpdates = aMsgs.filter((m) => (m as { method: string }).method === "session/update");
    const aResponse = aMsgs.find((m) => "result" in (m as { result?: unknown }));
    expect(aResponse).toMatchObject({ result: { stopReason: "end_turn" } });
    expect(aUpdates.length).toBe(2);
    for (const msgs of [aUpdates, bMsgs]) {
      expect(msgs.length).toBe(2);
      expect((msgs[0] as { method: string }).method).toBe("session/update");
      expect((msgs[0] as { params: { sessionId: string } }).params.sessionId).toBe(sessionId);
      expect((msgs[1] as { params: unknown }).params).toBeDefined();
    }

    wsA.close();
    wsB.close();
  }, 10000);

  test("injects an empty mcpServers default on session/new", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);
    send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/p" } });
    const msg = (await nextMessage(q)) as { result?: { mcpServers: unknown } };
    expect(msg.result?.mcpServers).toEqual([]);
    ws.close();
  });

  test("client disconnect does not stop the agent subprocess", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);
    ws.close();
    await new Promise((r) => setTimeout(r, 50));

    const alive = await acp.request<{ sessionId: string }>("session/new", { cwd: "/x" });
    expect(alive.sessionId).toMatch(/^sess_/);
  });
});

describe("session.list", () => {
  test("returns empty list when no sessions", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);
    send(ws, { jsonrpc: "2.0", id: 2, method: "session.list" });
    const msg = (await nextMessage(q)) as { result?: { sessions: Array<{ id: string; cwd: string; status: string }> } };
    expect(Array.isArray(msg.result?.sessions)).toBe(true);
    ws.close();
  });

  test("new sessions appear in list with cwd and active status", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);

    send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/proj/alpha" } });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;

    send(ws, { jsonrpc: "2.0", id: 3, method: "session.list" });
    const listMsg = (await nextMessage(q)) as { result?: { sessions: Array<{ id: string; cwd: string; status: string }> } };
    const found = listMsg.result?.sessions.find((s) => s.id === sessionId);
    expect(found).toBeDefined();
    expect(found?.cwd).toBe("/proj/alpha");
    expect(found?.status).toBe("active");
    ws.close();
  });

  test("two sessions from different cwds both appear in list", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);

    send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/proj/a" } });
    const m1 = (await nextMessage(q)) as { result?: { sessionId: string } };
    const idA = m1.result!.sessionId;

    send(ws, { jsonrpc: "2.0", id: 3, method: "session/new", params: { cwd: "/proj/b" } });
    const m2 = (await nextMessage(q)) as { result?: { sessionId: string } };
    const idB = m2.result!.sessionId;

    send(ws, { jsonrpc: "2.0", id: 4, method: "session.list" });
    const listMsg = (await nextMessage(q)) as { result?: { sessions: Array<{ id: string; cwd: string }> } };
    const sessList = listMsg.result!.sessions;
    expect(sessList.some((s) => s.id === idA && s.cwd === "/proj/a")).toBe(true);
    expect(sessList.some((s) => s.id === idB && s.cwd === "/proj/b")).toBe(true);
    ws.close();
  });
});

describe("session.resume", () => {
  test("resumes an existing session via ACP session/load", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);

    send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/proj/r" } });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;

    sessions.markInterrupted(sessionId);

    send(ws, { jsonrpc: "2.0", id: 3, method: "session.resume", params: { sessionId } });
    const resumeMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    expect(resumeMsg.result?.sessionId).toBe(sessionId);

    const listed = sessions.get(sessionId);
    expect(listed?.status).toBe("active");
    ws.close();
  });

  test("returns error for unknown sessionId", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);

    send(ws, { jsonrpc: "2.0", id: 2, method: "session.resume", params: { sessionId: "sess_nonexistent" } });
    const msg = (await nextMessage(q)) as { error?: { code: number } };
    expect(msg.error?.code).toBe(-32602);
    ws.close();
  });

  test("returns error when sessionId is missing", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);

    send(ws, { jsonrpc: "2.0", id: 2, method: "session.resume" });
    const msg = (await nextMessage(q)) as { error?: { code: number } };
    expect(msg.error?.code).toBe(-32602);
    ws.close();
  });

  test("after resume, can send a prompt", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);

    send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/proj/r2" } });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;

    sessions.markInterrupted(sessionId);

    send(ws, { jsonrpc: "2.0", id: 3, method: "session.resume", params: { sessionId } });
    await nextMessage(q);

    send(ws, {
      jsonrpc: "2.0",
      id: 4,
      method: "session/prompt",
      params: { sessionId, prompt: [{ type: "text", text: "resumed" }] },
    });
    const msgs = await collectMessages(q, 3);
    const response = msgs.find((m) => "result" in (m as { result?: unknown }));
    expect((response as { result?: { stopReason: string } }).result?.stopReason).toBe("end_turn");
    ws.close();
  }, 10000);
});

describe("persistence across restarts", () => {
  test("an active session reloads as interrupted after an abrupt restart", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);

    send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/proj/persist" } });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;
    expect(sessions.get(sessionId)?.status).toBe("active");

    // simulate a kill -9: no shutdown hook runs, we just read the store back
    const fresh = new SessionManager(join(tmpDir, "sessions.json"));
    fresh.load();
    const reloaded = fresh.get(sessionId);
    expect(reloaded).toBeDefined();
    expect(reloaded?.cwd).toBe("/proj/persist");
    expect(reloaded?.status).toBe("interrupted");
    ws.close();
  });

  test("an ended session stays ended after a restart", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);

    send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/proj/done" } });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;

    send(ws, { jsonrpc: "2.0", id: 3, method: "session.end", params: { sessionId } });
    const endMsg = (await nextMessage(q)) as { result?: { ok: boolean } };
    expect(endMsg.result?.ok).toBe(true);

    const fresh = new SessionManager(join(tmpDir, "sessions.json"));
    fresh.load();
    expect(fresh.get(sessionId)?.status).toBe("ended");
    ws.close();
  });
});

describe("session.end", () => {
  test("marks a session ended and it shows up in the list", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);

    send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/proj/e" } });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;

    send(ws, { jsonrpc: "2.0", id: 3, method: "session.end", params: { sessionId } });
    await nextMessage(q);

    send(ws, { jsonrpc: "2.0", id: 4, method: "session.list" });
    const listMsg = (await nextMessage(q)) as { result?: { sessions: Array<{ id: string; status: string }> } };
    const found = listMsg.result?.sessions.find((s) => s.id === sessionId);
    expect(found?.status).toBe("ended");
    ws.close();
  });

  test("returns error for unknown sessionId", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);

    send(ws, { jsonrpc: "2.0", id: 2, method: "session.end", params: { sessionId: "sess_nope" } });
    const msg = (await nextMessage(q)) as { error?: { code: number } };
    expect(msg.error?.code).toBe(-32602);
    ws.close();
  });
});