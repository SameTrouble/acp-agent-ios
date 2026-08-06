import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { AcpClient, type InitializeResult } from "../src/acp";
import type { AgentConfig, CompanionConfig } from "../src/config";
import { CompanionServer } from "../src/server";
import { SessionManager } from "../src/session";

const here = dirname(fileURLToPath(import.meta.url));
const embeddedAgentPath = join(here, "helpers", "mock-agent.ts");
const noEmbeddedAgentPath = join(here, "helpers", "mock-agent-no-embedded.ts");

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

function waitOpen(ws: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    ws.onopen = () => resolve();
    ws.onerror = () => reject(new Error("ws error"));
  });
}

function send(ws: WebSocket, obj: unknown): void {
  ws.send(JSON.stringify(obj));
}

function makeProjectDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "files-project-"));
  mkdirSync(join(dir, "src"), { recursive: true });
  mkdirSync(join(dir, "node_modules/pkg"), { recursive: true });
  writeFileSync(join(dir, "src/index.ts"), "export const answer = 42;\n");
  writeFileSync(join(dir, "src/helper.ts"), "export function help() {}\n");
  writeFileSync(join(dir, "README.md"), "# Project Readme\n");
  writeFileSync(join(dir, "node_modules/pkg/main.js"), "// vendor\n");
  return dir;
}

interface Harness {
  server: CompanionServer;
  acp: AcpClient;
  baseUrl: string;
  sessions: SessionManager;
}

async function startHarness(agentPath: string): Promise<Harness> {
  const tmpDir = mkdtempSync(join(tmpdir(), "files-companion-"));
  const agentConfig: AgentConfig = { command: "bun", args: [agentPath] };
  const config: CompanionConfig = {
    host: "127.0.0.1",
    port: 0,
    tokens: ["good-token"],
    agent: agentConfig,
    sessionStorePath: join(tmpDir, "sessions.json"),
    eventBufferCapacity: 100,
  };
  const sessions = new SessionManager(config.sessionStorePath);
  const acp = AcpClient.spawn(agentConfig);
  const agentInfo = (await acp.initialize()) as InitializeResult;
  const server = new CompanionServer({ config, acp, agentInfo, sessions });
  await server.listen();
  const baseUrl = server.url!.replace(/^http/, "ws");
  return { server, acp, baseUrl, sessions };
}

async function authedSocket(baseUrl: string): Promise<{ ws: WebSocket; q: QueuedSocket }> {
  const ws = new WebSocket(baseUrl);
  await waitOpen(ws);
  const q = makeQueue(ws);
  send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
  await nextMessage(q);
  return { ws, q };
}

async function newSession(ws: WebSocket, q: QueuedSocket, cwd: string): Promise<string> {
  send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd } });
  const msg = (await nextMessage(q)) as { result?: { sessionId: string } };
  return msg.result!.sessionId;
}

describe("files.search", () => {
  let h: Harness;
  let projectDir: string;

  beforeAll(async () => {
    h = await startHarness(embeddedAgentPath);
    projectDir = makeProjectDir();
  });

  afterAll(async () => {
    await h.server.stop();
    await h.acp.close();
  });

  test("requires authentication", async () => {
    const ws = new WebSocket(h.baseUrl);
    await waitOpen(ws);
    const q = makeQueue(ws);
    send(ws, { jsonrpc: "2.0", id: 1, method: "files.search", params: { sessionId: "x", query: "a" } });
    const msg = (await nextMessage(q)) as { error?: { code: number } };
    expect(msg.error?.code).toBe(-32001);
    ws.close();
  });

  test("returns error when sessionId is missing", async () => {
    const { ws, q } = await authedSocket(h.baseUrl);
    send(ws, { jsonrpc: "2.0", id: 2, method: "files.search", params: { query: "index" } });
    const msg = (await nextMessage(q)) as { error?: { code: number } };
    expect(msg.error?.code).toBe(-32602);
    ws.close();
  });

  test("returns error for unknown session", async () => {
    const { ws, q } = await authedSocket(h.baseUrl);
    send(ws, { jsonrpc: "2.0", id: 2, method: "files.search", params: { sessionId: "sess_nope", query: "x" } });
    const msg = (await nextMessage(q)) as { error?: { code: number } };
    expect(msg.error?.code).toBe(-32602);
    ws.close();
  });

  test("finds files in the session cwd by fuzzy query", async () => {
    const { ws, q } = await authedSocket(h.baseUrl);
    const sessionId = await newSession(ws, q, projectDir);

    send(ws, { jsonrpc: "2.0", id: 3, method: "files.search", params: { sessionId, query: "index" } });
    const msg = (await nextMessage(q)) as { result?: { files: Array<{ path: string; score: number }> } };
    const files = msg.result!.files;
    expect(files.length).toBeGreaterThan(0);
    expect(files.some((f) => f.path === "src/index.ts")).toBe(true);
    ws.close();
  });

  test("excludes node_modules from results", async () => {
    const { ws, q } = await authedSocket(h.baseUrl);
    const sessionId = await newSession(ws, q, projectDir);

    send(ws, { jsonrpc: "2.0", id: 3, method: "files.search", params: { sessionId, query: "main" } });
    const msg = (await nextMessage(q)) as { result?: { files: Array<{ path: string }> } };
    expect(msg.result!.files.some((f) => f.path.includes("node_modules"))).toBe(false);
    ws.close();
  });

  test("respects the limit parameter", async () => {
    const { ws, q } = await authedSocket(h.baseUrl);
    const sessionId = await newSession(ws, q, projectDir);

    send(ws, { jsonrpc: "2.0", id: 3, method: "files.search", params: { sessionId, query: "", limit: 2 } });
    const msg = (await nextMessage(q)) as { result?: { files: unknown[] } };
    expect(msg.result!.files.length).toBe(2);
    ws.close();
  });
});

describe("@reference expansion for an agent declaring embeddedContext", () => {
  let h: Harness;
  let projectDir: string;

  beforeAll(async () => {
    h = await startHarness(embeddedAgentPath);
    projectDir = makeProjectDir();
  });

  afterAll(async () => {
    await h.server.stop();
    await h.acp.close();
  });

  test("the agent's reply proves it received the file contents", async () => {
    const { ws, q } = await authedSocket(h.baseUrl);
    const sessionId = await newSession(ws, q, projectDir);

    send(ws, {
      jsonrpc: "2.0",
      id: 3,
      method: "session/prompt",
      params: {
        sessionId,
        prompt: [
          { type: "text", text: "explain " },
          { type: "file_ref", path: "src/index.ts" },
        ],
      },
    });

    const msgs = await collectMessages(q, 3);
    const echoed = msgs
      .filter((m) => (m as { method?: string }).method === "session/update")
      .map((m) => (m as { params: { update: { content: { text: string } } } }).params.update.content.text)
      .join("");

    expect(echoed).toContain("export const answer = 42;");
    ws.close();
  }, 10000);

  test("multiple file references interleaved with text all reach the agent", async () => {
    const { ws, q } = await authedSocket(h.baseUrl);
    const sessionId = await newSession(ws, q, projectDir);

    send(ws, {
      jsonrpc: "2.0",
      id: 3,
      method: "session/prompt",
      params: {
        sessionId,
        prompt: [
          { type: "text", text: "compare A:" },
          { type: "file_ref", path: "src/index.ts" },
          { type: "text", text: " with B:" },
          { type: "file_ref", path: "src/helper.ts" },
        ],
      },
    });

    const msgs = await collectMessages(q, 3);
    const echoed = msgs
      .filter((m) => (m as { method?: string }).method === "session/update")
      .map((m) => (m as { params: { update: { content: { text: string } } } }).params.update.content.text)
      .join("");

    expect(echoed).toContain("compare A:");
    expect(echoed).toContain("export const answer = 42;");
    expect(echoed).toContain("with B:");
    expect(echoed).toContain("export function help() {}");
    ws.close();
  }, 10000);

  test("prompts without file refs still work unchanged", async () => {
    const { ws, q } = await authedSocket(h.baseUrl);
    const sessionId = await newSession(ws, q, projectDir);

    send(ws, {
      jsonrpc: "2.0",
      id: 3,
      method: "session/prompt",
      params: { sessionId, prompt: [{ type: "text", text: "plain question" }] },
    });

    const msgs = await collectMessages(q, 3);
    const response = msgs.find((m) => "result" in (m as { result?: unknown }));
    expect((response as { result?: { stopReason: string } }).result?.stopReason).toBe("end_turn");
    ws.close();
  }, 10000);
});

describe("@reference expansion for an agent without embeddedContext", () => {
  let h: Harness;
  let projectDir: string;

  beforeAll(async () => {
    h = await startHarness(noEmbeddedAgentPath);
    projectDir = makeProjectDir();
  });

  afterAll(async () => {
    await h.server.stop();
    await h.acp.close();
  });

  test("file contents are not embedded, only linked", async () => {
    const { ws, q } = await authedSocket(h.baseUrl);
    const sessionId = await newSession(ws, q, projectDir);

    send(ws, {
      jsonrpc: "2.0",
      id: 3,
      method: "session/prompt",
      params: {
        sessionId,
        prompt: [
          { type: "text", text: "read " },
          { type: "file_ref", path: "src/index.ts" },
        ],
      },
    });

    const msgs = await collectMessages(q, 3);
    const echoed = msgs
      .filter((m) => (m as { method?: string }).method === "session/update")
      .map((m) => (m as { params: { update: { content: { text: string } } } }).params.update.content.text)
      .join("");

    expect(echoed).toContain("read ");
    expect(echoed).not.toContain("export const answer = 42;");
    ws.close();
  }, 10000);
});
