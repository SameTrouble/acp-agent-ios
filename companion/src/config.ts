import { readFileSync } from "node:fs";
import { DEFAULT_BARK_URL, type BarkConfig } from "./bark";

export interface CompanionConfig {
  host: string;
  port: number;
  tokens: string[];
  agent: AgentConfig;
  sessionStorePath: string;
  eventBufferCapacity: number;
  bark?: BarkConfig;
}

export interface AgentConfig {
  command: string;
  args: string[];
}

const DEFAULT_CONFIG: CompanionConfig = {
  host: "0.0.0.0",
  port: 8787,
  tokens: [],
  agent: {
    command: "opencode",
    args: ["acp"],
  },
  sessionStorePath: "",
  eventBufferCapacity: 1000,
};

export function defaultConfigPath(env: NodeJS.ProcessEnv = process.env): string {
  return `${configBase(env)}/acp-agent/companion.json`;
}

export function defaultSessionStorePath(env: NodeJS.ProcessEnv = process.env): string {
  return `${configBase(env)}/acp-agent/sessions.json`;
}

function configBase(env: NodeJS.ProcessEnv): string {
  const xdg = env.XDG_CONFIG_HOME;
  const home = env.HOME;
  return xdg && xdg.length > 0
    ? xdg
    : home && home.length > 0
      ? `${home}/.config`
      : ".";
}

export function loadConfig(
  path?: string,
  env: NodeJS.ProcessEnv = process.env,
): CompanionConfig {
  const filePath = path ?? defaultConfigPath(env);
  let raw: unknown;
  try {
    raw = JSON.parse(readFile(filePath));
  } catch (err) {
    if (isMissingFile(err)) {
      throw new Error(
        `config file not found at ${filePath}. Create it with a "tokens" array and optional "port".`,
      );
    }
    const e = err as Error;
    throw new Error(`failed to read config at ${filePath}: ${e.message}`);
  }

  const parsed = parseConfig(raw);
  return parsed;
}

export function parseConfig(raw: unknown): CompanionConfig {
  if (typeof raw !== "object" || raw === null) {
    throw new Error("config must be a JSON object");
  }
  const obj = raw as Record<string, unknown>;

  const tokens = parseTokens(obj.tokens);
  const port = parsePort(obj.port);
  const host = typeof obj.host === "string" && obj.host.length > 0 ? obj.host : DEFAULT_CONFIG.host;
  const agent = parseAgent(obj.agent);
  const sessionStorePath = typeof obj.sessionStorePath === "string" && obj.sessionStorePath.length > 0
    ? obj.sessionStorePath
    : defaultSessionStorePath();
  const eventBufferCapacity = parseEventBufferCapacity(obj.eventBufferCapacity);
  const bark = parseBarkConfig(obj.bark);

  return { host, port, tokens, agent, sessionStorePath, eventBufferCapacity, ...(bark ? { bark } : {}) };
}

function parseEventBufferCapacity(value: unknown): number {
  if (value === undefined) return DEFAULT_CONFIG.eventBufferCapacity;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1) {
    throw new Error(
      `config "eventBufferCapacity" must be a positive integer, got ${JSON.stringify(value)}`,
    );
  }
  return value;
}

/**
 * Parses the optional `bark` section. An absent section or an empty device
 * key disables notifications; the per-trigger switches default to on once a
 * device key is present (explicit opt-in happens via the key itself).
 */
function parseBarkConfig(value: unknown): BarkConfig | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "object" || value === null) {
    throw new Error('config "bark" must be an object');
  }
  const obj = value as Record<string, unknown>;
  const deviceKey = parseBarkDeviceKey(obj.deviceKey);
  if (deviceKey.length === 0) return undefined;
  const url = parseBarkUrl(obj.url);
  const notifyOnApproval = parseBarkSwitch(obj.notifyOnApproval, "notifyOnApproval");
  const notifyOnSessionEnd = parseBarkSwitch(obj.notifyOnSessionEnd, "notifyOnSessionEnd");
  return { deviceKey, url, notifyOnApproval, notifyOnSessionEnd };
}

function parseBarkDeviceKey(value: unknown): string {
  if (typeof value !== "string") {
    throw new Error('config "bark.deviceKey" must be a string');
  }
  return value;
}

function parseBarkUrl(value: unknown): string {
  if (value === undefined) return DEFAULT_BARK_URL;
  if (typeof value !== "string" || value.length === 0) {
    throw new Error('config "bark.url" must be a non-empty string');
  }
  return value;
}

function parseBarkSwitch(value: unknown, name: string): boolean {
  if (value === undefined) return true;
  if (typeof value !== "boolean") {
    throw new Error(`config "bark.${name}" must be a boolean`);
  }
  return value;
}

function parseTokens(value: unknown): string[] {
  if (!Array.isArray(value) || value.length === 0) {
    throw new Error('config "tokens" must be a non-empty array of strings');
  }
  for (const t of value) {
    if (typeof t !== "string" || t.length === 0) {
      throw new Error('config "tokens" must contain only non-empty strings');
    }
  }
  return value as string[];
}

function parsePort(value: unknown): number {
  if (value === undefined) return DEFAULT_CONFIG.port;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1 || value > 65535) {
    throw new Error(`config "port" must be an integer in [1, 65535], got ${JSON.stringify(value)}`);
  }
  return value;
}

function parseAgent(value: unknown): AgentConfig {
  if (value === undefined) return DEFAULT_CONFIG.agent;
  if (typeof value !== "object" || value === null) {
    throw new Error('config "agent" must be an object');
  }
  const obj = value as Record<string, unknown>;
  const command = typeof obj.command === "string" && obj.command.length > 0
    ? obj.command
    : DEFAULT_CONFIG.agent.command;
  const args = Array.isArray(obj.args)
    ? obj.args.filter((a): a is string => typeof a === "string")
    : DEFAULT_CONFIG.agent.args;
  return { command, args };
}

function readFile(path: string): string {
  return readFileSync(path, "utf8");
}

function isMissingFile(err: unknown): boolean {
  return (
    typeof err === "object" &&
    err !== null &&
    "code" in err &&
    (err as { code?: string }).code === "ENOENT"
  );
}