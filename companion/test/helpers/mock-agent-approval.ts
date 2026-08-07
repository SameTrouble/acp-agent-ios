import { createFramedParser, encodeFrame, isRequest } from "../../src/rpc";

/**
 * Mock ACP agent that exercises the Bark notification wires (issue #10):
 * every `session/prompt` emits a `session/request_permission` request and
 * answers it itself, resolves the tool call, streams one message chunk, then
 * ends the turn. A prompt whose text is exactly "fail" makes the turn fail
 * with a JSON-RPC error instead.
 */

const SESSION_PREFIX = "sess_";

const sessions = new Map<string, { cwd: string }>();

function promptText(prompt: unknown): string {
  if (!Array.isArray(prompt)) return "";
  return prompt
    .map((b) => {
      if (typeof b !== "object" || b === null) return "";
      const obj = b as Record<string, unknown>;
      if (obj.type === "text" && typeof obj.text === "string") return obj.text;
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
            loadSession: true,
          },
          agentInfo: { name: "mock-agent-approval", version: "1.0.0" },
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
      if (text.trim() === "fail") {
        return encodeFrame({
          jsonrpc: "2.0",
          id: msg.id,
          error: { code: -32000, message: "provider auth failed" },
        });
      }
      const frames = [
        {
          jsonrpc: "2.0" as const,
          id: 0,
          method: "session/request_permission",
          params: {
            sessionId,
            toolCall: {
              toolCallId: "call_1",
              title: "curl -s example.com",
              kind: "execute",
              status: "pending",
              locations: [],
              rawInput: { command: "curl -s example.com" },
            },
            options: [
              { optionId: "once", kind: "allow_once", name: "Allow once" },
              { optionId: "reject", kind: "reject_once", name: "Reject" },
            ],
          },
        },
        { jsonrpc: "2.0" as const, id: 0, result: { outcome: { outcome: "selected", optionId: "once" } } },
        {
          jsonrpc: "2.0" as const,
          method: "session/update",
          params: {
            sessionId,
            update: { sessionUpdate: "tool_call_update", toolCallId: "call_1", status: "completed", title: "curl -s example.com" },
          },
        },
        {
          jsonrpc: "2.0" as const,
          method: "session/update",
          params: {
            sessionId,
            update: { sessionUpdate: "agent_message_chunk", messageId: "msg_1", content: { type: "text", text: "done" } },
          },
        },
      ];
      return frames.map((f) => encodeFrame(f)).join("") +
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
      }
    }
  }
};
void pump();
