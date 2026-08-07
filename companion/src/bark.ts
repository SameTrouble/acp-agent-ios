import { basename } from "node:path";

export interface BarkConfig {
  deviceKey: string;
  url: string;
  notifyOnApproval: boolean;
  notifyOnSessionEnd: boolean;
}

export const DEFAULT_BARK_URL = "https://api.day.app";

export const DISABLED_BARK: BarkConfig = {
  deviceKey: "",
  url: DEFAULT_BARK_URL,
  notifyOnApproval: false,
  notifyOnSessionEnd: false,
};

export interface SessionRef {
  id: string;
  cwd?: string;
}

export interface ApprovalToolCall {
  toolCallId: string;
  title?: string;
}

export type TurnEndKind = "success" | "failure" | "none";

export interface TurnEndOutcome {
  kind: TurnEndKind;
  detail?: string;
}

/**
 * Maps a `session/prompt` outcome to a notification kind. Verified against
 * opencode 1.18.13: the response's `stopReason` is `end_turn` on success,
 * `cancelled` when the client aborted, `max_tokens`/`refusal` on truncated or
 * refused runs; provider/service failures reject the request with an RpcError.
 * Only `end_turn` is a clean success; `cancelled` is a user action inside the
 * app and must not pull them back with a push.
 */
export function classifyTurnEnd(result: unknown, error: unknown): TurnEndOutcome {
  if (error) {
    return { kind: "failure", detail: error instanceof Error ? error.message : String(error) };
  }
  if (typeof result !== "object" || result === null) return { kind: "none" };
  const stopReason = (result as { stopReason?: unknown }).stopReason;
  if (typeof stopReason !== "string") return { kind: "none" };
  switch (stopReason) {
    case "end_turn":
      return { kind: "success" };
    case "cancelled":
      return { kind: "none" };
    default:
      return { kind: "failure", detail: `stopReason: ${stopReason}` };
  }
}

export type BarkSender = (url: string) => Promise<unknown>;

/** Bark notification level: urgency hint shown on the device. */
export type BarkLevel = "active" | "timeSensitive" | "passive";

const MAX_TITLE_LENGTH = 60;
const MAX_BODY_LENGTH = 200;

export interface BarkNotifierOptions {
  /** Test seam; defaults to a fetch-based sender. */
  sender?: BarkSender;
  log?: (message: string) => void;
}

/**
 * Pushes Bark notifications for approval requests and session ends. Every
 * trigger type has its own config switch; the notifier is a no-op when the
 * device key is empty. Sends are fire-and-forget and never throw.
 */
export class BarkNotifier {
  private config: BarkConfig;
  private sender: BarkSender;
  private log: (message: string) => void;
  private notifiedApprovals = new Set<string>();

  constructor(config: BarkConfig, opts: BarkNotifierOptions = {}) {
    this.config = config;
    this.sender = opts.sender ?? defaultSender;
    this.log = opts.log ?? ((message) => console.error(message));
  }

  get enabled(): boolean {
    return this.config.deviceKey.length > 0;
  }

  /**
   * Pushes once per (session, toolCallId): the same approval request must not
   * spam the phone while it is still pending. The entry is removed again when
   * the tool call reaches a terminal state (`resolveApproval`) or the turn
   * ends (`clearSession`), so a genuinely re-asked request can notify again.
   */
  async notifyApproval(session: SessionRef, toolCall: ApprovalToolCall): Promise<void> {
    if (!this.enabled || !this.config.notifyOnApproval) return;
    const key = `${session.id}\u0000${toolCall.toolCallId}`;
    if (this.notifiedApprovals.has(key)) return;
    this.notifiedApprovals.add(key);

    const title = withProject("需要审批", session);
    const body = `${truncate(toolCall.title ?? "工具请求", MAX_BODY_LENGTH)}\n${session.id}`;
    await this.send(title, body, `approval:${session.id}`, "timeSensitive");
  }

  resolveApproval(sessionId: string, toolCallId: string): void {
    this.notifiedApprovals.delete(`${sessionId}\u0000${toolCallId}`);
  }

  clearSession(sessionId: string): void {
    const prefix = `${sessionId}\u0000`;
    for (const key of this.notifiedApprovals) {
      if (key.startsWith(prefix)) this.notifiedApprovals.delete(key);
    }
  }

  async notifySessionEnded(session: SessionRef, outcome: TurnEndOutcome): Promise<void> {
    if (!this.enabled || !this.config.notifyOnSessionEnd || outcome.kind === "none") return;
    const group = `sessionEnd:${session.id}`;
    if (outcome.kind === "success") {
      await this.send(withProject("会话完成", session), session.id, group);
      return;
    }
    const detail = outcome.detail ? `\n${truncate(outcome.detail, MAX_BODY_LENGTH)}` : "";
    await this.send(withProject("会话失败", session), `${session.id}${detail}`, group, "timeSensitive");
  }

  private async send(title: string, body: string, group: string, level?: BarkLevel): Promise<void> {
    if (!this.enabled) return;
    const base = this.config.url.replace(/\/+$/, "");
    const params = new URLSearchParams({ group });
    if (level) params.set("level", level);
    const url = [
      base,
      encodeURIComponent(this.config.deviceKey),
      encodeURIComponent(truncate(title, MAX_TITLE_LENGTH)),
      encodeURIComponent(truncate(body, MAX_BODY_LENGTH)),
    ].join("/") + `?${params.toString()}`;
    try {
      await this.sender(url);
    } catch (err) {
      this.log(`bark notification failed: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
}

function withProject(base: string, session: SessionRef): string {
  const project = projectName(session);
  return project.length > 0 ? `${base} · ${project}` : base;
}

function projectName(session: SessionRef): string {
  if (!session.cwd) return "";
  const name = basename(session.cwd);
  return name.length > 0 ? name : session.cwd;
}

async function defaultSender(url: string): Promise<unknown> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`bark responded ${res.status}`);
  return res;
}

function truncate(value: string, max: number): string {
  return value.length <= max ? value : `${value.slice(0, max - 1)}…`;
}
