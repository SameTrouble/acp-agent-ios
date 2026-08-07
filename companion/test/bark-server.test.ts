import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { AcpClient, type InitializeResult } from "../src/acp";
import { BarkNotifier, type BarkConfig } from "../src/bark";
import type { AgentConfig, CompanionConfig } from "../src/config";
import { CompanionServer } from "../src/server";
import { SessionManager } from "../src/session";

const here = dirname(fileURLToPath(import.meta.url));
const mockAgentPath = join(here, "helpers", "mock-agent-approval.ts");
const agentConfig: AgentConfig = { command: "bun", args: [mockAgentPath] };

interface Harness {
  server: CompanionServer;
  acp: AcpClient;
  sent: string[];
  baseUrl: string;
}

async function startHarness(bark: BarkConfig): Promise<Harness> {
  const tmpDir = mkdtempSync(join(tmpdir(), "companion-bark-"));
  const sessions = new SessionManager(join(tmpDir, "sessions.json"));
  const acp = AcpClient.spawn(agentConfig);
  const agentInfo = (await acp.initialize()) as InitializeResult;
  const sent: string[] = [];
  const config: CompanionConfig = {
    host: "127.0.0.1",
    port: 0,
    tokens: ["good-token"],
    agent: agentConfig,
    sessionStorePath: "",
    eventBufferCapacity: 100,
    bark,
  };
  const notifier = new BarkNotifier(bark, {
    sender: async (url) => {
      sent.push(url);
      return { ok: true };
    },
  });
  const server = new CompanionServer({ config, acp, agentInfo, sessions, notifier });
  await server.listen();
  return { server, acp, sent, baseUrl: server.url!.replace(/^http/, "ws") };
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

/** Opens a session in /proj/demo, sends one prompt and waits for its response. */
async function runPrompt(baseUrl: string, prompt: string): Promise<string> {
  const ws = new WebSocket(baseUrl);
  await waitOpen(ws);
  const q = makeQueue(ws);
  send(ws, { jsonrpc: "2.0", id: 1, method: "auth", params: { token: "good-token" } });
  await nextMessage(q);
  send(ws, { jsonrpc: "2.0", id: 2, method: "session/new", params: { cwd: "/proj/demo" } });
  const newMsg = (await nextMessage(q)) as { result?: { sessionId: string } };
  const sessionId = newMsg.result!.sessionId;
  send(ws, {
    jsonrpc: "2.0",
    id: 3,
    method: "session/prompt",
    params: { sessionId, prompt: [{ type: "text", text: prompt }] },
  });
  for (;;) {
    const msg = (await nextMessage(q)) as { id?: unknown };
    if (msg.id === 3) break;
  }
  ws.close();
  return sessionId;
}

const bothOn: BarkConfig = {
  deviceKey: "keyA",
  url: "https://bark.example.com",
  notifyOnApproval: true,
  notifyOnSessionEnd: true,
};

const approvalOff: BarkConfig = {
  ...bothOn,
  deviceKey: "keyB",
  notifyOnApproval: false,
};

let harnessA: Harness;
let harnessB: Harness;

beforeAll(async () => {
  harnessA = await startHarness(bothOn);
  harnessB = await startHarness(approvalOff);
});

afterAll(async () => {
  await harnessA.server.stop();
  await harnessA.acp.close();
  await harnessB.server.stop();
  await harnessB.acp.close();
});

describe("bark notifications (server wiring)", () => {
  test("a pending approval and a successful turn end each push once", async () => {
    const sessionId = await runPrompt(harnessA.baseUrl, "hello");
    expect(harnessA.sent).toHaveLength(2);

    const approval = decodeURIComponent(harnessA.sent[0]!);
    expect(approval).toContain("https://bark.example.com/keyA/");
    expect(approval).toContain("需要审批 · demo");
    expect(approval).toContain("curl -s example.com");
    expect(approval).toContain(sessionId);
    expect(approval).toContain("group=approval:" + sessionId);
    expect(approval).toContain("level=timeSensitive");

    const end = decodeURIComponent(harnessA.sent[1]!);
    expect(end).toContain("会话完成 · demo");
    expect(end).toContain(sessionId);
    expect(end).toContain("group=sessionEnd:" + sessionId);
  });

  test("a failing turn pushes a failure notification with the error", async () => {
    const before = harnessA.sent.length;
    await runPrompt(harnessA.baseUrl, "fail");
    const pushed = harnessA.sent.slice(before);
    expect(pushed).toHaveLength(1);
    const decoded = decodeURIComponent(pushed[0]!);
    expect(decoded).toContain("会话失败 · demo");
    expect(decoded).toContain("provider auth failed");
  });

  test("notifyOnApproval off suppresses approval pushes but not session end", async () => {
    const before = harnessB.sent.length;
    await runPrompt(harnessB.baseUrl, "hello");
    const pushed = harnessB.sent.slice(before);
    expect(pushed).toHaveLength(1);
    const decoded = decodeURIComponent(pushed[0]!);
    expect(decoded).toContain("会话完成");
    expect(decoded).not.toContain("需要审批");
  });
});
