import { spawn } from "bun";
import { writeFileSync } from "node:fs";

/**
 * Live wire observation harness for the real opencode ACP binary.
 *
 * Drives one full session (initialize → authenticate → session/new →
 * session/prompt) against `opencode acp` and records every JSON-RPC frame
 * (notifications, responses, and agent-side requests such as
 * `session/request_permission`) to a JSONL file, so the permission wire
 * shape can be reproduced and diffed across opencode versions.
 *
 * See ADR-005 (request_permission wire) for the recorded findings.
 *
 * Usage (from companion/):
 *   bun run scripts/observe-wire.ts <cwd> <outfile.jsonl>
 *
 * Env:
 *   PROBE_PROMPT        prompt to send (default: run a curl command)
 *   PERMISSION_REPLY    "once" (default) | "reject" — how to answer
 *                       session/request_permission requests
 *   XDG_CONFIG_HOME     opencode config dir (inherited from the shell;
 *                       point it at a temp config to force permission
 *                       rules like {"permission": {"bash": "ask"}})
 */
const CWD = process.argv[2] ?? process.cwd();
const OUTFILE = process.argv[3] ?? "./wire-observation.jsonl";
const PROMPT = process.env.PROBE_PROMPT ?? "执行 bash 命令: curl -s https://example.com | head -3";
const REPLY = process.env.PERMISSION_REPLY === "reject" ? "reject" : "once";

const proc = spawn({
  cmd: ["opencode", "acp"],
  stdout: "pipe",
  stdin: "pipe",
  stderr: "pipe",
});

const frames: unknown[] = [];
const replied = new WeakSet<object>();
let buffer = "";

function pump(stream: ReadableStream<Uint8Array>, label: string): void {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  const loop = async (): Promise<void> => {
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        const text = decoder.decode(value, { stream: true });
        buffer += text;
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";
        for (const line of lines) {
          if (line.trim().length === 0) continue;
          let msg: unknown;
          try {
            msg = JSON.parse(line);
          } catch {
            console.log(`[${label}-nonjson] ${line}`);
            continue;
          }
          frames.push(msg);
          console.log(`[${label}] ${JSON.stringify(msg)}`);
        }
      }
    } catch {
      // stream read errors after teardown are expected
    }
  };
  void loop();
}

pump(proc.stdout as ReadableStream<Uint8Array>, "stdout");
pump(proc.stderr as ReadableStream<Uint8Array>, "stderr");

const sink = proc.stdin as unknown as { write(chunk: string): void };
let nextId = 1;

function send(obj: unknown): void {
  sink.write(JSON.stringify(obj) + "\n");
}

async function request(method: string, params: unknown, timeoutMs = 180_000): Promise<unknown> {
  const id = nextId++;
  send({ jsonrpc: "2.0", id, method, params });
  const waitUntil = Date.now() + timeoutMs;
  for (;;) {
    const hit = frames.find((m) => {
      const o = m as { id?: unknown };
      return o.id === id && "result" in (m as Record<string, unknown>);
    });
    if (hit) return hit;
    if (Date.now() > waitUntil) throw new Error(`timeout waiting for ${method}`);
    await Bun.sleep(50);
  }
}

try {
  // 1. initialize — the real binary's capability + auth surface
  const init = (await request("initialize", {
    protocolVersion: 1,
    clientCapabilities: {},
    clientInfo: { name: "wire-observe", version: "0.0.1" },
  }, 30_000)) as { result?: { authMethods?: Array<{ id: string }> } };
  const auth = init.result?.authMethods?.[0]?.id;

  // 2. authenticate — opencode accepts without terminal interaction
  if (auth) {
    await request("authenticate", { methodId: auth }, 30_000);
  }

  // 3. session/new
  const sn = (await request("session/new", { cwd: CWD, mcpServers: [] }, 30_000)) as {
    result?: { sessionId?: string };
  };
  const sessionId = sn.result?.sessionId;

  // 4. session/prompt — answer agent-side requests (exactly once per frame)
  const promptId = nextId++;
  send({
    jsonrpc: "2.0",
    id: promptId,
    method: "session/prompt",
    params: { sessionId, prompt: [{ type: "text", text: PROMPT }] },
  });
  const waitUntil = Date.now() + 240_000;
  for (;;) {
    for (const m of frames) {
      if (typeof m !== "object" || m === null) continue;
      const f = m as { id?: unknown; method?: string };
      if (f.id === undefined || typeof f.method !== "string" || replied.has(m)) continue;
      if (f.method === "session/request_permission") {
        const reply = REPLY === "reject"
          ? { outcome: { outcome: "rejected" } }
          : { outcome: { outcome: "selected", optionId: REPLY } };
        send({ jsonrpc: "2.0", id: f.id, result: reply });
        console.log(`[probe] replied to ${f.method} id=${f.id} with ${JSON.stringify(reply)}`);
        replied.add(m);
        continue;
      }
      // Unknown agent-side request: reply method-not-found so the agent unblocks.
      send({
        jsonrpc: "2.0",
        id: f.id,
        error: { code: -32601, message: `unknown agent-side request ${f.method}` },
      });
      console.log(`[probe] replied error to unknown request ${f.method} id=${f.id}`);
      replied.add(m);
    }
    const hit = frames.find((m) => {
      const o = m as { id?: unknown };
      return o.id === promptId && "result" in (m as Record<string, unknown>);
    });
    if (hit) break;
    if (Date.now() > waitUntil) throw new Error("timeout waiting for session/prompt");
    await Bun.sleep(50);
  }

  // 5. drain trailing notifications, then tear down
  await Bun.sleep(3000);
  proc.kill();
  await proc.exited.catch(() => {});

  // Summary: which session/update variants and agent-side requests appeared
  const variants = new Map<string, number>();
  const agentRequests = new Set<string>();
  for (const m of frames) {
    const o = m as {
      method?: string;
      params?: { update?: { sessionUpdate?: string } };
      id?: unknown;
      result?: unknown;
      error?: unknown;
    };
    if (o.method === "session/update" && o.params?.update?.sessionUpdate) {
      const name = o.params.update.sessionUpdate;
      variants.set(name, (variants.get(name) ?? 0) + 1);
    }
    if (typeof o.method === "string" && o.id !== undefined && !("result" in (o as object)) && !("error" in (o as object))) {
      agentRequests.add(o.method);
    }
  }
  console.log("=== SUMMARY ===");
  console.log(`total frames: ${frames.length}`);
  console.log("session/update variants observed:");
  for (const [v, n] of variants) console.log(`  ${v}: ${n}`);
  console.log(`agent-side requests observed: ${[...agentRequests].join(", ") || "(none)"}`);

  writeFileSync(OUTFILE, frames.map((f) => JSON.stringify(f)).join("\n") + "\n", "utf8");
  console.log(`observation written to ${OUTFILE}`);
  process.exit(0);
} catch (err) {
  console.error(`FAILED: ${(err as Error).message}`);
  writeFileSync(OUTFILE, frames.map((f) => JSON.stringify(f)).join("\n") + "\n", "utf8");
  proc.kill();
  await proc.exited.catch(() => {});
  process.exit(1);
}
