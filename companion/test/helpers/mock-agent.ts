import { createFramedParser, encodeFrame, isNotification, isRequest, isResponse } from "../../src/rpc";

const SESSION_PREFIX = "sess_";

const sessions = new Map<string, { cwd: string }>();

/**
 * A `session/prompt` whose text starts with `ask ` triggers the permission
 * path: the mock sends a `session/request_permission` request (ADR-005 wire
 * shape) and holds the prompt until the client answers, then emits the
 * matching `tool_call_update` (completed on allow, failed on reject) and
 * completes the prompt.
 */
interface PendingPermission {
  promptId: number | string;
  sessionId: string;
  requestId: number;
  toolCallId: string;
}

let pendingPermission: PendingPermission | undefined;
let permissionRequestId = 0;

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
            loadSession: true,
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
      return encodeFrame({
        jsonrpc: "2.0",
        id: msg.id,
        result: {
          sessionId,
          mcpServers: p.mcpServers,
          configOptions: [
            {
              id: "model",
              name: "Model",
              category: "model",
              type: "select",
              currentValue: "model-1",
              options: [
                { value: "model-1", name: "Model 1" },
                { value: "model-2", name: "Model 2" },
              ],
            },
            {
              id: "mode",
              name: "Mode",
              category: "mode",
              type: "select",
              currentValue: "build",
              options: [
                { value: "build", name: "Build" },
                { value: "plan", name: "Plan" },
              ],
            },
          ],
        },
      });
    }
    case "session/load": {
      const p = (msg.params ?? {}) as { sessionId?: string; mcpServers?: unknown };
      const sessionId = p.sessionId;
      if (!sessionId || !sessions.has(sessionId)) {
        return encodeFrame({ jsonrpc: "2.0", id: msg.id, error: { code: -32602, message: "session not found" } });
      }
      return encodeFrame({ jsonrpc: "2.0", id: msg.id, result: { sessionId, mcpServers: p.mcpServers } });
    }
    case "session/set_config_option": {
      const p = (msg.params ?? {}) as { sessionId?: string; configId?: string; value?: string };
      const sessionId = p.sessionId;
      if (!sessionId || !sessions.has(sessionId)) {
        return encodeFrame({ jsonrpc: "2.0", id: msg.id, error: { code: -32602, message: "session not found" } });
      }
      const modelValue = p.configId === "model" && typeof p.value === "string" ? p.value : "model-1";
      const modeValue = p.configId === "mode" && typeof p.value === "string" ? p.value : "build";
      return encodeFrame({
        jsonrpc: "2.0",
        id: msg.id,
        result: {
          configOptions: [
            {
              id: "model",
              name: "Model",
              category: "model",
              type: "select",
              currentValue: modelValue,
              options: [
                { value: "model-1", name: "Model 1" },
                { value: "model-2", name: "Model 2" },
              ],
            },
            {
              id: "mode",
              name: "Mode",
              category: "mode",
              type: "select",
              currentValue: modeValue,
              options: [
                { value: "build", name: "Build" },
                { value: "plan", name: "Plan" },
              ],
            },
          ],
        },
      });
    }
    case "session/prompt": {
      const p = (msg.params ?? {}) as { sessionId?: string; prompt?: unknown };
      const sessionId = p.sessionId ?? "sess_unknown";
      const text = promptText(p.prompt);
      if (text.startsWith("ask ")) {
        const toolTitle = text.slice(4);
        const requestId = ++permissionRequestId;
        const toolCallId = "call_ask_" + requestId;
        pendingPermission = { promptId: msg.id, sessionId, requestId, toolCallId };
        return (
          encodeFrame({
            jsonrpc: "2.0",
            method: "session/update",
            params: {
              sessionId,
              update: { sessionUpdate: "tool_call", toolCallId, title: toolTitle, kind: "execute", status: "pending" },
            },
          }) +
          encodeFrame({
            jsonrpc: "2.0",
            id: requestId,
            method: "session/request_permission",
            params: {
              sessionId,
              toolCall: {
                toolCallId,
                title: toolTitle,
                kind: "execute",
                status: "pending",
                locations: [],
                rawInput: { command: toolTitle },
              },
              options: [
                { optionId: "once", kind: "allow_once", name: "Allow once" },
                { optionId: "always", kind: "allow_always", name: "Always allow" },
                { optionId: "reject", kind: "reject_once", name: "Reject" },
              ],
            },
          })
        );
      }
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
      } else if (isResponse(msg)) {
        // The only response the mock waits for is the permission reply.
        if (pendingPermission && msg.id === pendingPermission.requestId) {
          const result = (msg.result as { outcome?: { outcome?: string } } | undefined);
          const selected = result?.outcome?.outcome === "selected";
          const { promptId, sessionId, toolCallId } = pendingPermission;
          pendingPermission = undefined;
          const status = selected ? "completed" : "failed";
          const text = selected
            ? "executed"
            : "The user rejected permission to use this specific tool call.";
          const out =
            encodeFrame({
              jsonrpc: "2.0",
              method: "session/update",
              params: {
                sessionId,
                update: {
                  sessionUpdate: "tool_call_update",
                  toolCallId,
                  status,
                  content: [{ type: "content", content: { type: "text", text } }],
                },
              },
            }) +
            encodeFrame({ jsonrpc: "2.0", id: promptId, result: { stopReason: "end_turn" } });
          void Bun.stdout.write(out);
        }
        // Any other response is out-of-order / stale and is ignored.
      } else if (isNotification(msg)) {
        // notifications are ignored by the mock
      }
    }
  }
};
void pump();