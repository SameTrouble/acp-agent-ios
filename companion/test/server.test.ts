import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { AcpClient, type InitializeResult } from "../src/acp";
import type { AgentConfig, CompanionConfig } from "../src/config";
import { CompanionServer } from "../src/server";

const here = dirname(fileURLToPath(import.meta.url));
const mockAgentPath = join(here, "helpers", "mock-agent.ts");

const agentConfig: AgentConfig = { command: "bun", args: [mockAgentPath] };
const config: CompanionConfig = {
  host: "127.0.0.1",
  port: 0,
  tokens: ["good-token", "second-token"],
  agent: agentConfig,
};

let server: CompanionServer;
let acp: AcpClient;
let baseUrl: string;

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
  acp = AcpClient.spawn(agentConfig);
  const agentInfo = (await acp.initialize()) as InitializeResult;
  server = new CompanionServer({ config, acp, agentInfo });
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