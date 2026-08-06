import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { AcpClient } from "../src/acp";
import type { AgentConfig } from "../src/config";

const here = dirname(fileURLToPath(import.meta.url));
const mockAgentPath = join(here, "helpers", "mock-agent.ts");

const agentConfig: AgentConfig = {
  command: "bun",
  args: [mockAgentPath],
};

let client: AcpClient;
let notifications: Array<{ method: string; params?: unknown }> = [];
let requests: Array<{ id: number | string; method: string; params?: unknown }> = [];

beforeAll(() => {
  client = AcpClient.spawn(agentConfig, {
    onNotification: (n) => notifications.push(n),
    onRequest: (r) => requests.push(r),
  });
});

afterEach(() => {
  requests = [];
});

afterAll(async () => {
  await client.close();
});

describe("AcpClient", () => {
  test("initialize returns agent info and auth methods", async () => {
    const result = await client.initialize();
    expect(result.protocolVersion).toBe(1);
    expect(result.agentInfo.name).toBe("mock-agent");
    expect(result.agentCapabilities).toBeDefined();
    expect(result.authMethods).toContainEqual({ id: "agent-login", name: "Agent login" });
  });

  test("authenticate succeeds", async () => {
    const result = await client.request("authenticate", { methodId: "agent-login" });
    expect(result).toEqual({});
  });

  test("session/new returns a session id", async () => {
    const result = await client.request<{ sessionId: string }>("session/new", { cwd: "/x" });
    expect(result.sessionId).toMatch(/^sess_/);
  });

  test("session/prompt streams updates and returns a stop reason", async () => {
    const before = notifications.length;
    const result = await client.request<{ stopReason: string }>("session/prompt", {
      sessionId: "sess_1",
      prompt: [{ type: "text", text: "hi" }],
    });
    expect(result.stopReason).toBe("end_turn");
    const newNotifications = notifications.slice(before);
    expect(newNotifications.length).toBeGreaterThan(0);
    expect(newNotifications[0]!.method).toBe("session/update");
  });

  test("unknown method returns an error", async () => {
    await expect(client.request("nope")).rejects.toThrow(/method not found/);
  });

  test("agent permission requests are delivered to the request handler", async () => {
    const before = requests.length;
    const prompt = client.request<{ stopReason: string }>("session/prompt", {
      sessionId: "sess_perm",
      prompt: [{ type: "text", text: "ask curl -s http://example.com" }],
    });

    // Wait for the request_permission frame from the agent.
    const deadline = Date.now() + 2000;
    while (requests.length === before && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 10));
    }
    const permission = requests.slice(before).find((r) => r.method === "session/request_permission");
    expect(permission).toBeDefined();
    const params = permission!.params as {
      sessionId: string;
      toolCall: { title: string; toolCallId: string };
      options: Array<{ optionId: string; kind: string; name: string }>;
    };
    expect(params.sessionId).toBe("sess_perm");
    expect(params.toolCall.title).toBe("curl -s http://example.com");
    expect(params.options).toEqual([
      { optionId: "once", kind: "allow_once", name: "Allow once" },
      { optionId: "always", kind: "allow_always", name: "Always allow" },
      { optionId: "reject", kind: "reject_once", name: "Reject" },
    ]);

    // The prompt stays open until the client answers; replying allow_once lets
    // it finish and the tool executes.
    client.respond(permission!.id, { outcome: { outcome: "selected", optionId: "once" } });
    const result = await prompt;
    expect(result.stopReason).toBe("end_turn");
  }, 10000);

  test("rejecting a permission request fails the tool and still ends the turn", async () => {
    const before = requests.length;
    const prompt = client.request<{ stopReason: string }>("session/prompt", {
      sessionId: "sess_reject",
      prompt: [{ type: "text", text: "ask write /etc/hosts" }],
    });

    const deadline = Date.now() + 2000;
    while (requests.length === before && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 10));
    }
    const permission = requests.slice(before).find((r) => r.method === "session/request_permission");
    expect(permission).toBeDefined();

    client.respond(permission!.id, { outcome: { outcome: "rejected" } });
    const result = await prompt;
    expect(result.stopReason).toBe("end_turn");
  }, 10000);
});