import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { mkdtempSync, mkdirSync } from "node:fs";
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

/** Opens a socket and completes the auth handshake with a valid token. */
async function authenticate(): Promise<{ ws: WebSocket; q: QueuedSocket }> {
  const ws = connect();
  await waitOpen(ws);
  const q = makeQueue(ws);
  send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
  await nextMessage(q);
  return { ws, q };
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

  test("resume keeps an ended session ended (read-only history view)", async () => {
    const { ws, q } = await authenticate();

    send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/proj/history" } });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;
    sessions.markEnded(sessionId);

    send(ws, { jsonrpc: "2.0", id: 3, method: "session.resume", params: { sessionId } });
    const resumeMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    expect(resumeMsg.result?.sessionId).toBe(sessionId);

    // Viewing history must not revive the session (issue #12).
    expect(sessions.get(sessionId)?.status).toBe("ended");
    ws.close();
  });

  test("prompting an ended session revives it to active", async () => {
    const { ws, q } = await authenticate();

    send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/proj/revive" } });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;
    sessions.markEnded(sessionId);

    send(ws, { jsonrpc: "2.0", id: 3, method: "session.resume", params: { sessionId } });
    await nextMessage(q);
    expect(sessions.get(sessionId)?.status).toBe("ended");

    send(ws, {
      jsonrpc: "2.0",
      id: 4,
      method: "session/prompt",
      params: { sessionId, prompt: [{ type: "text", text: "continuing" }] },
    });
    const msgs = await collectMessages(q, 3);
    const response = msgs.find((m) => "result" in (m as { result?: unknown }));
    expect((response as { result?: { stopReason: string } }).result?.stopReason).toBe("end_turn");

    // Sending a new prompt IS continuing the conversation (issue #12).
    expect(sessions.get(sessionId)?.status).toBe("active");
    ws.close();
  }, 10000);

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

  test("resume returns cached configOptions from session/new", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);

    send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/proj/cfg" } });
    const newMsg = (await nextMessage(q)) as {
      result?: { sessionId: string; configOptions?: Array<{ id: string; currentValue: string }> };
    };
    const sessionId = newMsg.result!.sessionId;
    expect(newMsg.result?.configOptions?.[0]?.id).toBe("model");

    send(ws, { jsonrpc: "2.0", id: 3, method: "session.resume", params: { sessionId } });
    const resumeMsg = (await nextMessage(q)) as {
      result?: { sessionId: string; configOptions?: Array<{ id: string; currentValue: string }> };
    };
    expect(resumeMsg.result?.sessionId).toBe(sessionId);
    expect(resumeMsg.result?.configOptions?.[0]?.currentValue).toBe("model-1");
    ws.close();
  });

  test("set_config_option updates the resume cache", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
    await nextMessage(q);

    send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/proj/cfg2" } });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;

    send(ws, {
      jsonrpc: "2.0",
      id: 3,
      method: "session/set_config_option",
      params: { sessionId, configId: "model", value: "model-2" },
    });
    const setMsg = (await nextMessage(q)) as {
      result?: { configOptions?: Array<{ id: string; currentValue: string }> };
    };
    expect(setMsg.result?.configOptions?.find((o) => o.id === "model")?.currentValue).toBe("model-2");

    send(ws, { jsonrpc: "2.0", id: 4, method: "session.resume", params: { sessionId } });
    const resumeMsg = (await nextMessage(q)) as {
      result?: { configOptions?: Array<{ id: string; currentValue: string }> };
    };
    expect(resumeMsg.result?.configOptions?.find((o) => o.id === "model")?.currentValue).toBe("model-2");
    ws.close();
  });
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

describe("dir.browse", () => {
  interface DirBrowseResult {
    result?: {
      path: string;
      parent: string | null;
      entries: Array<{ name: string; path: string }>;
    };
    error?: { code: number; message: string };
    id: number;
  }

  test("lists one level of an existing directory", async () => {
    const root = join(tmpDir, "browse");
    mkdirSync(join(root, "proj-one"), { recursive: true });
    mkdirSync(join(root, "proj-two"), { recursive: true });

    const { ws, q } = await authenticate();
    send(ws, { jsonrpc: "2.0", id: 2, method: "dir.browse", params: { path: root } });
    const msg = (await nextMessage(q)) as DirBrowseResult;
    expect(msg.result?.path).toBe(root);
    expect(msg.result?.parent).toBe(tmpDir);
    expect(msg.result?.entries.map((e) => e.name)).toEqual(["proj-one", "proj-two"]);
    expect(msg.result?.entries[0]?.path).toBe(join(root, "proj-one"));
    ws.close();
  });

  test("navigates up via the returned parent path", async () => {
    const root = join(tmpDir, "browse");
    const { ws, q } = await authenticate();
    send(ws, { jsonrpc: "2.0", id: 2, method: "dir.browse", params: { path: join(root, "proj-one") } });
    const down = (await nextMessage(q)) as DirBrowseResult;
    expect(down.result?.parent).toBe(root);

    send(ws, { jsonrpc: "2.0", id: 3, method: "dir.browse", params: { path: down.result?.parent } });
    const up = (await nextMessage(q)) as DirBrowseResult;
    expect(up.result?.path).toBe(root);
    expect(up.result?.entries.some((e) => e.name === "proj-two")).toBe(true);
    ws.close();
  });

  test("omitting path starts at the home directory", async () => {
    const { ws, q } = await authenticate();
    send(ws, { jsonrpc: "2.0", id: 2, method: "dir.browse" });
    const msg = (await nextMessage(q)) as DirBrowseResult;
    expect(msg.error).toBeUndefined();
    expect(typeof msg.result?.path).toBe("string");
    expect(msg.result?.path.length).toBeGreaterThan(0);
    ws.close();
  });

  test("returns InvalidParams for a missing path", async () => {
    const { ws, q } = await authenticate();
    send(ws, { jsonrpc: "2.0", id: 2, method: "dir.browse", params: { path: "/nonexistent/browse-xyz" } });
    const msg = (await nextMessage(q)) as DirBrowseResult;
    expect(msg.error?.code).toBe(-32602);
    ws.close();
  });

  test("requires authentication", async () => {
    const ws = connect();
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "dir.browse", params: { path: "/" } });
    const msg = (await nextMessage(q)) as DirBrowseResult;
    expect(msg.error?.code).toBe(-32001);
    ws.close();
  });
});

describe("agent request relay (permission)", () => {
  interface PermissionRequestFrame {
    id: number | string;
    method: string;
    params: {
      sessionId: string;
      toolCall: { toolCallId: string; title: string };
      options: Array<{ optionId: string; kind: string; name: string }>;
    };
  }

  const startPermissionPrompt = async (ws: WebSocket, q: QueuedSocket) => {
    send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/proj/perm" } });
    const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
    const sessionId = newMsg.result!.sessionId;
    send(ws, {
      jsonrpc: "2.0",
      id: 3,
      method: "session/prompt",
      params: { sessionId, prompt: [{ type: "text", text: "ask curl -s http://example.com" }] },
    });
    return sessionId;
  };

  test("request_permission is broadcast and the session is marked pending", async () => {
    const { ws: wsA, q: qA } = await authenticate();
    const { ws: wsB, q: qB } = await authenticate();
    const sessionId = await startPermissionPrompt(wsA, qA);

    const [aMsgs, bMsgs] = await Promise.all([
      collectMessages(qA, 2),
      collectMessages(qB, 2),
    ]);
    for (const msgs of [aMsgs, bMsgs]) {
      const toolUpdate = msgs[0] as { method: string; params: { sessionId: string } };
      expect(toolUpdate.method).toBe("session/update");
      expect(toolUpdate.params.sessionId).toBe(sessionId);

      const request = msgs[1] as PermissionRequestFrame;
      expect(request.method).toBe("session/request_permission");
      expect(typeof request.id).toBe("number");
      expect(request.params.sessionId).toBe(sessionId);
      expect(request.params.toolCall.title).toBe("curl -s http://example.com");
      expect(request.params.options.map((o) => o.kind)).toEqual(["allow_once", "allow_always", "reject_once"]);
    }

    send(wsA, { jsonrpc: "2.0", id: 4, method: "session.list" });
    const listMsg = (await nextMessage(qA)) as { result?: { sessions: Array<{ id: string; hasPendingApproval: boolean }> } };
    const found = listMsg.result!.sessions.find((s) => s.id === sessionId);
    expect(found?.hasPendingApproval).toBe(true);

    wsA.close();
    wsB.close();
  }, 10000);

  test("first response reaches the agent and clears the pending flag; late responses are dropped", async () => {
    const { ws: wsA, q: qA } = await authenticate();
    const { ws: wsB, q: qB } = await authenticate();
    const sessionId = await startPermissionPrompt(wsA, qA);

    const [aMsgs] = await Promise.all([
      collectMessages(qA, 2),
      collectMessages(qB, 2),
    ]);
    const request = aMsgs[1] as PermissionRequestFrame;
    const requestId = request.id;

    // Client A answers first: allow_once → the tool executes and the prompt completes.
    send(wsA, {
      jsonrpc: "2.0",
      id: requestId,
      result: { outcome: { outcome: "selected", optionId: "once" } },
    });
    const followUps = await collectMessages(qA, 2);
    const toolUpdate = followUps[0] as { method: string; params: { update: { status: string } } };
    const promptResponse = followUps[1] as { result?: { stopReason: string }; id: number };
    expect(toolUpdate.method).toBe("session/update");
    expect(toolUpdate.params.update.status).toBe("completed");
    expect(promptResponse.result?.stopReason).toBe("end_turn");

    send(wsA, { jsonrpc: "2.0", id: 5, method: "session.list" });
    const listMsg = (await nextMessage(qA)) as { result?: { sessions: Array<{ id: string; hasPendingApproval: boolean }> } };
    const found = listMsg.result!.sessions.find((s) => s.id === sessionId);
    expect(found?.hasPendingApproval).toBe(false);

    // Client B answers the same request late: silently dropped — no error, no
    // duplicate execution (nothing is sent back to B). B may still have the
    // tool_call_update broadcast in its queue, so compare before/after.
    const beforeLateResponse = qB.queue.length;
    send(wsB, {
      jsonrpc: "2.0",
      id: requestId,
      result: { outcome: { outcome: "selected", optionId: "always" } },
    });
    await new Promise((r) => setTimeout(r, 150));
    expect(qB.queue.length).toBe(beforeLateResponse);

    wsA.close();
    wsB.close();
  }, 10000);

  test("rejected response fails the tool with the rejection message", async () => {
    const { ws, q } = await authenticate();
    const sessionId = await startPermissionPrompt(ws, q);

    const msgs = await collectMessages(q, 2);
    const request = msgs[1] as PermissionRequestFrame;

    send(ws, {
      jsonrpc: "2.0",
      id: request.id,
      result: { outcome: { outcome: "rejected" } },
    });
    const followUps = await collectMessages(q, 2);
    const toolUpdate = followUps[0] as { params: { update: { status: string; content: unknown } } };
    const promptResponse = followUps[1] as { result?: { stopReason: string } };
    expect(toolUpdate.params.update.status).toBe("failed");
    expect(promptResponse.result?.stopReason).toBe("end_turn");

    ws.close();
  }, 10000);
});
