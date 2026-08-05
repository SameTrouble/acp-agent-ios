import { afterAll, beforeAll, describe, expect, test } from "bun:test";
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

beforeAll(() => {
  client = AcpClient.spawn(agentConfig, {
    onNotification: (n) => notifications.push(n),
  });
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
});