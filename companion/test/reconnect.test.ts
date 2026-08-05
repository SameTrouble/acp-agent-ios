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
const mockAgentNoLoadPath = join(here, "helpers", "mock-agent-no-load.ts");

const agentConfig: AgentConfig = { command: "bun", args: [mockAgentPath] };
const baseConfig: CompanionConfig = {
  host: "127.0.0.1",
  port: 0,
  tokens: ["good-token"],
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

async function authClient(): Promise<{ ws: WebSocket; q: QueuedSocket }> {
  const ws = connect();
  await waitOpen(ws);
  const q = makeQueue(ws);
  send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
  await nextMessage(q);
  return { ws, q };
}

beforeAll(async () => {
  tmpDir = mkdtempSync(join(tmpdir(), "companion-reconnect-"));
  sessions = new SessionManager(join(tmpDir, "sessions.json"));
  acp = AcpClient.spawn(agentConfig);
  const agentInfo = (await acp.initialize()) as InitializeResult;
  server = new CompanionServer({ config: baseConfig, acp, agentInfo, sessions });
  await server.listen();
  const url = server.url!;
  baseUrl = url.replace(/^http/, "ws");
});

afterAll(async () => {
  await server.stop();
  await acp.close();
});

describe("broadcast includes cursor", () => {
  test("session/update notifications carry a cursor field", async () => {
    const { ws, q } = await authClient();
    send(ws, {
      jsonrpc: "2.0",
      id: 2,
      method: "session/new",
      params: { cwd: "/cursor-test" },
    });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;

    send(ws, {
      jsonrpc: "2.0",
      id: 3,
      method: "session/prompt",
      params: { sessionId, prompt: [{ type: "text", text: "hi" }] },
    });

    const updates: unknown[] = [];
    for (let i = 0; i < 3; i++) {
      const msg = await nextMessage(q);
      if ((msg as { method?: string }).method === "session/update") {
        updates.push(msg);
      }
    }

    expect(updates.length).toBeGreaterThanOrEqual(2);
    for (let i = 0; i < updates.length; i++) {
      const u = updates[i] as { cursor: number; params: { sessionId: string } };
      expect(typeof u.cursor).toBe("number");
      expect(u.params.sessionId).toBe(sessionId);
    }
    const cursors = updates.map((u) => (u as { cursor: number }).cursor);
    expect(cursors).toEqual(cursors.slice().sort((a, b) => a - b));
    ws.close();
  }, 10000);
});

describe("session.resume with cursor — replay mode", () => {
  test("replays buffered events since the cursor, no duplicates no loss", async () => {
    const { ws: wsA, q: qA } = await authClient();

    send(wsA, {
      jsonrpc: "2.0",
      id: 2,
      method: "session/new",
      params: { cwd: "/proj/replay" },
    });
    const newMsg = (await nextMessage(qA)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;

    send(wsA, {
      jsonrpc: "2.0",
      id: 3,
      method: "session/prompt",
      params: { sessionId, prompt: [{ type: "text", text: "first" }] },
    });

    const updates: unknown[] = [];
    for (let i = 0; i < 3; i++) {
      const msg = await nextMessage(qA);
      if ((msg as { method?: string }).method === "session/update") {
        updates.push(msg);
      }
    }
    expect(updates.length).toBeGreaterThanOrEqual(2);
    const lastCursor = (updates[updates.length - 1] as { cursor: number }).cursor;

    send(wsA, {
      jsonrpc: "2.0",
      id: 4,
      method: "session/prompt",
      params: { sessionId, prompt: [{ type: "text", text: "second" }] },
    });

    const secondUpdates: unknown[] = [];
    for (let i = 0; i < 3; i++) {
      const msg = await nextMessage(qA);
      if ((msg as { method?: string }).method === "session/update") {
        secondUpdates.push(msg);
      }
    }
    const totalAfterSecond = lastCursor + secondUpdates.length;

    const { ws: wsB, q: qB } = await authClient();
    send(wsB, {
      jsonrpc: "2.0",
      id: 5,
      method: "session.resume",
      params: { sessionId, cursor: lastCursor },
    });

    const resumeMsg = (await nextMessage(qB)) as {
      result?: { recovery: string; events: Array<{ cursor: number }>; cursor: number };
    };
    expect(resumeMsg.result?.recovery).toBe("replay");
    expect(resumeMsg.result?.events.length).toBe(secondUpdates.length);
    expect(resumeMsg.result?.cursor).toBe(totalAfterSecond);

    for (let i = 0; i < resumeMsg.result!.events.length; i++) {
      expect(resumeMsg.result!.events[i]!.cursor).toBe(lastCursor + 1 + i);
    }

    wsA.close();
    wsB.close();
  }, 10000);

  test("replay with latest cursor returns empty events array", async () => {
    const { ws, q } = await authClient();
    send(ws, {
      jsonrpc: "2.0",
      id: 2,
      method: "session/new",
      params: { cwd: "/proj/empty-replay" },
    });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;

    send(ws, {
      jsonrpc: "2.0",
      id: 3,
      method: "session/prompt",
      params: { sessionId, prompt: [{ type: "text", text: "x" }] },
    });

    const updates: unknown[] = [];
    for (let i = 0; i < 3; i++) {
      const msg = await nextMessage(q);
      if ((msg as { method?: string }).method === "session/update") {
        updates.push(msg);
      }
    }
    const latestCursor = (updates[updates.length - 1] as { cursor: number }).cursor;

    send(ws, {
      jsonrpc: "2.0",
      id: 4,
      method: "session.resume",
      params: { sessionId, cursor: latestCursor },
    });

    const resumeMsg = (await nextMessage(q)) as {
      result?: { recovery: string; events: unknown[]; cursor: number };
    };
    expect(resumeMsg.result?.recovery).toBe("replay");
    expect(resumeMsg.result?.events.length).toBe(0);
    expect(resumeMsg.result?.cursor).toBe(latestCursor);
    ws.close();
  }, 10000);

  test("invalid cursor value returns InvalidParams error", async () => {
    const { ws, q } = await authClient();
    send(ws, {
      jsonrpc: "2.0",
      id: 2,
      method: "session/new",
      params: { cwd: "/proj/bad-cursor" },
    });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;

    send(ws, {
      jsonrpc: "2.0",
      id: 3,
      method: "session.resume",
      params: { sessionId, cursor: "not-a-number" },
    });
    const msg = (await nextMessage(q)) as { error?: { code: number; message: string } };
    expect(msg.error?.code).toBe(-32602);
    expect(msg.error?.message).toContain("cursor");
    ws.close();
  });
});

describe("session.resume with cursor — snapshot mode (buffer miss, agent supports load)", () => {
  test("falls back to session/load snapshot when cursor is evicted", async () => {
    const smallBufConfig: CompanionConfig = {
      ...baseConfig,
      eventBufferCapacity: 2,
    };
    const smallAcp = AcpClient.spawn(agentConfig);
    const agentInfo = (await smallAcp.initialize()) as InitializeResult;
    const smallSessions = new SessionManager(join(tmpDir, "sessions-small.json"));
    const smallServer = new CompanionServer({ config: smallBufConfig, acp: smallAcp, agentInfo, sessions: smallSessions });
    await smallServer.listen();
    const smallUrl = smallServer.url!.replace(/^http/, "ws");

    const ws = new WebSocket(smallUrl);
    await new Promise<void>((resolve) => { ws.onopen = () => resolve(); });
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);

    send(ws, {
      jsonrpc: "2.0",
      id: 2,
      method: "session/new",
      params: { cwd: "/proj/snapshot" },
    });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;

    send(ws, {
      jsonrpc: "2.0",
      id: 3,
      method: "session/prompt",
      params: { sessionId, prompt: [{ type: "text", text: "first overflow" }] },
    });
    for (let i = 0; i < 3; i++) await nextMessage(q);

    send(ws, {
      jsonrpc: "2.0",
      id: 4,
      method: "session/prompt",
      params: { sessionId, prompt: [{ type: "text", text: "second overflow" }] },
    });
    for (let i = 0; i < 3; i++) await nextMessage(q);

    send(ws, {
      jsonrpc: "2.0",
      id: 5,
      method: "session.resume",
      params: { sessionId, cursor: 0 },
    });
    const resumeMsg = (await nextMessage(q)) as {
      result?: { recovery: string; sessionId: string; cursor: number };
    };
    expect(resumeMsg.result?.recovery).toBe("snapshot");
    expect(resumeMsg.result?.sessionId).toBe(sessionId);

    ws.close();
    await smallServer.stop();
    await smallAcp.close();
  }, 10000);
});

describe("session.resume with cursor — live-only degradation", () => {
  test("degrades to live-only when agent lacks loadSession capability and cursor is evicted", async () => {
    const noLoadConfig: AgentConfig = { command: "bun", args: [mockAgentNoLoadPath] };
    const smallBufConfig: CompanionConfig = {
      ...baseConfig,
      agent: noLoadConfig,
      eventBufferCapacity: 2,
    };
    const noLoadAcp = AcpClient.spawn(noLoadConfig);
    const agentInfo = (await noLoadAcp.initialize()) as InitializeResult;
    const noLoadSessions = new SessionManager(join(tmpDir, "sessions-noload.json"));
    const noLoadServer = new CompanionServer({ config: smallBufConfig, acp: noLoadAcp, agentInfo, sessions: noLoadSessions });
    await noLoadServer.listen();
    const noLoadUrl = noLoadServer.url!.replace(/^http/, "ws");

    const ws = new WebSocket(noLoadUrl);
    await new Promise<void>((resolve) => { ws.onopen = () => resolve(); });
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);

    send(ws, {
      jsonrpc: "2.0",
      id: 2,
      method: "session/new",
      params: { cwd: "/proj/degraded" },
    });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;

    send(ws, {
      jsonrpc: "2.0",
      id: 3,
      method: "session/prompt",
      params: { sessionId, prompt: [{ type: "text", text: "first" }] },
    });
    for (let i = 0; i < 3; i++) await nextMessage(q);

    send(ws, {
      jsonrpc: "2.0",
      id: 4,
      method: "session/prompt",
      params: { sessionId, prompt: [{ type: "text", text: "second" }] },
    });
    for (let i = 0; i < 3; i++) await nextMessage(q);

    send(ws, {
      jsonrpc: "2.0",
      id: 5,
      method: "session.resume",
      params: { sessionId, cursor: 0 },
    });
    const resumeMsg = (await nextMessage(q)) as {
      result?: { recovery: string; sessionId: string; reason: string };
    };
    expect(resumeMsg.result?.recovery).toBe("live-only");
    expect(resumeMsg.result?.sessionId).toBe(sessionId);
    expect(resumeMsg.result?.reason).toBeDefined();

    ws.close();
    await noLoadServer.stop();
    await noLoadAcp.close();
  }, 10000);
});

describe("buffer is bounded per session", () => {
  test("session end clears its buffer (no unbounded growth)", async () => {
    const { ws, q } = await authClient();
    send(ws, {
      jsonrpc: "2.0",
      id: 2,
      method: "session/new",
      params: { cwd: "/proj/end-clear" },
    });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;

    send(ws, {
      jsonrpc: "2.0",
      id: 3,
      method: "session/prompt",
      params: { sessionId, prompt: [{ type: "text", text: "x" }] },
    });
    for (let i = 0; i < 3; i++) {
      await nextMessage(q);
    }

    send(ws, {
      jsonrpc: "2.0",
      id: 4,
      method: "session.end",
      params: { sessionId },
    });
    const endMsg = (await nextMessage(q)) as { result?: { ok: boolean } };
    expect(endMsg.result?.ok).toBe(true);

    send(ws, {
      jsonrpc: "2.0",
      id: 5,
      method: "session.resume",
      params: { sessionId, cursor: 0 },
    });
    const resumeMsg = (await nextMessage(q)) as { result?: { recovery: string } };
    expect(resumeMsg.result?.recovery).toBe("snapshot");
    ws.close();
  }, 10000);
});
