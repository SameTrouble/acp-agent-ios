/**
 * A mock ACP agent that does NOT declare the `loadSession` capability, and
 * rejects `session/load`. Used to exercise the live-only degradation path.
 */
import { createFramedParser, encodeFrame, isNotification, isRequest, isResponse } from "../../src/rpc";

const SESSION_PREFIX = "sess_";

const sessions = new Map<string, { cwd: string }>();

function promptText(prompt: unknown): string {
  if (!Array.isArray(prompt)) return "";
  return prompt
    .map((b) => {
      if (typeof b !== "object" || b === null) return "";
      const obj = b as Record<string, unknown>;
      if (obj.type === "text" && typeof obj.text === "string") return obj.text;
      if (obj.type === "resource" && typeof obj.resource === "object" && obj.resource !== null) {
        const r = obj.resource as { text?: unknown };
        return typeof r.text === "string" ? r.text : "";
      }
      return "";
    })
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
          agentInfo: { name: "mock-agent-no-load", version: "1.0.0" },
          authMethods: [],
        },
      });
    case "session/new": {
      const p = (msg.params ?? {}) as { cwd?: string; mcpServers?: unknown };
      const sessionId = SESSION_PREFIX + Math.random().toString(16).slice(2, 10);
      sessions.set(sessionId, { cwd: p.cwd ?? "/" });
      return encodeFrame({ jsonrpc: "2.0", id: msg.id, result: { sessionId, mcpServers: p.mcpServers } });
    }
    case "session/load":
      return encodeFrame({
        jsonrpc: "2.0",
        id: msg.id,
        error: { code: -32601, message: "session/load is not supported" },
      });
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
const reader = Bun.stdin.stream().getReader();
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
        void Bun.stdout.write(handleRequest({ id: msg.id as number | string, method: msg.method, params: msg.params }));
      } else if (isNotification(msg) || isResponse(msg)) {
        // ignored by the mock
      }
    }
  }
};
void pump();
