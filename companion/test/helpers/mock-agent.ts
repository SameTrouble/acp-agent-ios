import { createFramedParser, encodeFrame, isNotification, isRequest, isResponse } from "../../src/rpc";

const SESSION_PREFIX = "sess_";

const sessions = new Map<string, { cwd: string }>();

function promptText(prompt: unknown): string {
  if (!Array.isArray(prompt)) return "";
  return prompt
    .map((b) => (typeof b === "object" && b !== null && typeof (b as { text?: unknown }).text === "string" ? (b as { text: string }).text : ""))
    .join("");
}

function handleRequest(msg: { id: number | string; method: string; params?: unknown }): string {
  switch (msg.method) {
    case "initialize":
      return encodeFrame({
        jsonrpc: "2.0",
        id: msg.id,
        result: {
          protocolVersion: 1,
          agentCapabilities: {
            promptCapabilities: { embeddedContext: true },
          },
          agentInfo: { name: "mock-agent", version: "1.0.0" },
          authMethods: [{ id: "agent-login", name: "Agent login" }],
        },
      });
    case "authenticate":
      return encodeFrame({ jsonrpc: "2.0", id: msg.id, result: {} });
    case "session/new": {
      const p = (msg.params ?? {}) as { cwd?: string; mcpServers?: unknown };
      const sessionId = SESSION_PREFIX + Math.random().toString(16).slice(2, 10);
      sessions.set(sessionId, { cwd: p.cwd ?? "/" });
      return encodeFrame({ jsonrpc: "2.0", id: msg.id, result: { sessionId, mcpServers: p.mcpServers } });
    }
    case "session/load": {
      const p = (msg.params ?? {}) as { sessionId?: string; mcpServers?: unknown };
      const sessionId = p.sessionId;
      if (!sessionId || !sessions.has(sessionId)) {
        return encodeFrame({ jsonrpc: "2.0", id: msg.id, error: { code: -32602, message: "session not found" } });
      }
      return encodeFrame({ jsonrpc: "2.0", id: msg.id, result: { sessionId, mcpServers: p.mcpServers } });
    }
    case "session/prompt": {
      const p = (msg.params ?? {}) as { sessionId?: string; prompt?: unknown };
      const sessionId = p.sessionId ?? "sess_unknown";
      const text = promptText(p.prompt);
      const updates = [
        { jsonrpc: "2.0" as const, method: "session/update", params: { sessionId, update: { sessionUpdate: "agent_message_chunk", messageId: "msg_1", content: { type: "text", text: "hello" } } } },
        { jsonrpc: "2.0" as const, method: "session/update", params: { sessionId, update: { sessionUpdate: "agent_message_chunk", messageId: "msg_1", content: { type: "text", text: " " + text } } } },
      ];
      return updates.map((u) => encodeFrame(u)).join("") +
        encodeFrame({ jsonrpc: "2.0", id: msg.id, result: { stopReason: "end_turn" } });
    }
    default:
      return encodeFrame({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: `method not found: ${msg.method}` } });
  }
}

const parser = createFramedParser();
const stdin = Bun.stdin.stream();
const reader = stdin.getReader();
const pump = async (): Promise<void> => {
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    const text = new TextDecoder().decode(value);
    for (const frame of parser(text)) {
      let msg: unknown;
      try {
        msg = JSON.parse(frame);
      } catch {
        continue;
      }
      if (isRequest(msg)) {
        const out = handleRequest({ id: msg.id as number | string, method: msg.method, params: msg.params });
        void Bun.stdout.write(out);
      } else if (isNotification(msg) || isResponse(msg)) {
        // notifications / out-of-order responses are ignored by the mock
      }
    }
  }
};
void pump();