import type { Server, ServerWebSocket, WebSocketHandler } from "bun";
import type { AcpClient, InitializeResult } from "./acp";
import type { CompanionConfig } from "./config";
import type { SessionManager } from "./session";
import {
  BarkNotifier,
  classifyTurnEnd,
  DISABLED_BARK,
  type ApprovalToolCall,
  type SessionRef,
} from "./bark";
import { SessionEventBuffer } from "./session-event-buffer";
import {
  AppErrorCodes,
  ErrorCodes,
  isNotification,
  isRequest,
  isResponse,
  makeError,
  makeResponse,
  RpcError,
  type JsonRpcResponse,
} from "./rpc";
import { searchFiles } from "./file-search";
import { expandPrompt } from "./prompt-expander";

interface ClientState {
  authenticated: boolean;
}

const LOCAL_METHODS = new Set(["auth", "initialize", "session.list", "session.resume", "session.end", "files.search"]);

// opencode requires mcpServers on session lifecycle requests; inject an empty
// default so clients don't have to know.
const SESSION_LIFECYCLE_METHODS = new Set(["session/new", "session/load", "session/resume"]);

export type RecoveryMode = "replay" | "snapshot" | "live-only";

export interface CompanionServerOptions {
  config: CompanionConfig;
  acp: AcpClient;
  agentInfo: InitializeResult;
  sessions: SessionManager;
  /** Test seam; defaults to a notifier built from the config's bark section. */
  notifier?: BarkNotifier;
}

export class CompanionServer {
  private server: Server<ClientState> | undefined;
  private clients: ServerWebSocket<ClientState>[] = [];
  private config: CompanionConfig;
  private acp: AcpClient;
  private agentInfo: InitializeResult;
  private sessions: SessionManager;
  private events: SessionEventBuffer;
  private notifier: BarkNotifier;
  /**
   * Outstanding agent→client request ids awaiting a client response. The value
   * is the request's session id (for the pending flag) or undefined for
   * requests without one.
   */
  private agentRequests = new Map<number | string, string | undefined>();

  constructor(opts: CompanionServerOptions) {
    this.config = opts.config;
    this.acp = opts.acp;
    this.agentInfo = opts.agentInfo;
    this.sessions = opts.sessions;
    this.events = new SessionEventBuffer(opts.config.eventBufferCapacity);
    this.notifier = opts.notifier ?? new BarkNotifier(opts.config.bark ?? DISABLED_BARK);
  }

  async listen(): Promise<void> {
    this.acp.setNotificationHandler(({ method, params }) => {
      this.sessions.handleNotification(method, params);
      this.onAgentNotification(method, params);
      const cursor = this.recordEvent(method, params);
      this.broadcast({
        jsonrpc: "2.0",
        method,
        ...(params !== undefined ? { params } : {}),
        ...(cursor !== undefined ? { cursor } : {}),
      });
    });

    // Agent→client requests (e.g. session/request_permission) are relayed to
    // every client; the first response routed back wins (ADR-005). Bark
    // observes the same request for the approval push (issue #10).
    this.acp.setRequestHandler(({ id, method, params }) => {
      this.onAgentRequest(method, params);
      const sessionId = this.sessionIdFromParams(params);
      if (sessionId) this.sessions.setPendingApproval(sessionId, true);
      this.agentRequests.set(id, sessionId);
      const cursor = this.recordAgentRequest(method, params, id);
      this.broadcast({
        jsonrpc: "2.0",
        id,
        method,
        ...(params !== undefined ? { params } : {}),
        ...(cursor !== undefined ? { cursor } : {}),
      });
    });

    this.server = Bun.serve<ClientState>({
      hostname: this.config.host,
      port: this.config.port,
      fetch: (req, server) => {
        if (server.upgrade(req, { data: { authenticated: false } })) {
          return;
        }
        return new Response("acp-agent-companion", { status: 1001 });
      },
      websocket: this.websocketHandler(),
    });
  }

  async stop(): Promise<void> {
    this.server?.stop(true);
  }

  get url(): string | undefined {
    return this.server?.url.toString();
  }

  private websocketHandler(): WebSocketHandler<ClientState> {
    return {
      open: (ws) => {
        this.clients.push(ws);
      },
      message: (ws, message) => void this.handleMessage(ws, message),
      close: (ws) => {
        this.clients = this.clients.filter((c) => c !== ws);
      },
    };
  }

  private isAuthenticated(ws: ServerWebSocket<ClientState>): boolean {
    return ws.data.authenticated;
  }

  private send(ws: ServerWebSocket<ClientState>, obj: unknown): void {
    if (ws.readyState === 1) {
      ws.send(JSON.stringify(obj));
    }
  }

  private async handleMessage(ws: ServerWebSocket<ClientState>, message: string | Buffer): Promise<void> {
    let msg: unknown;
    try {
      msg = JSON.parse(String(message));
    } catch {
      this.send(ws, makeError(0, ErrorCodes.ParseError, "invalid JSON"));
      return;
    }

    if (isResponse(msg)) {
      this.handleClientResponse(ws, msg);
      return;
    }

    if (!isRequest(msg) && !isNotification(msg)) {
      this.send(ws, makeError(0, ErrorCodes.InvalidRequest, "expected a JSON-RPC request or notification"));
      return;
    }

    const id = "id" in msg ? msg.id as string | number : undefined;

    if (msg.method === "auth") {
      this.handleAuth(ws, id, msg.params);
      return;
    }

    if (!this.isAuthenticated(ws)) {
      this.sendError(ws, id ?? 0, AppErrorCodes.Unauthorized, "not authenticated: send auth first");
      return;
    }

    if (LOCAL_METHODS.has(msg.method)) {
      this.handleLocal(ws, id ?? 0, msg.method, msg.params);
      return;
    }

    await this.forward(ws, msg);
  }

  /**
   * Routes a client's reply to an agent→client request back to the agent. Only
   * the first response for a given id is forwarded — a late response from a
   * second device is dropped silently (no error, no duplicate execution).
   */
  private handleClientResponse(ws: ServerWebSocket<ClientState>, msg: JsonRpcResponse): void {
    if (!this.isAuthenticated(ws)) {
      this.send(ws, makeError(0, AppErrorCodes.Unauthorized, "not authenticated: send auth first"));
      return;
    }
    if (!this.agentRequests.has(msg.id)) return;
    const sessionId = this.agentRequests.get(msg.id);
    this.agentRequests.delete(msg.id);
    if (sessionId) this.sessions.setPendingApproval(sessionId, false);
    if (msg.error) {
      this.acp.respondError(msg.id, msg.error.code, msg.error.message);
    } else {
      this.acp.respond(msg.id, msg.result);
    }
  }

  private handleAuth(ws: ServerWebSocket<ClientState>, id: string | number | undefined, params: unknown): void {
    const p = (params ?? {}) as Record<string, unknown>;
    const token = typeof p.token === "string" ? p.token : "";
    if (this.config.tokens.includes(token)) {
      ws.data.authenticated = true;
      this.send(ws, makeResponse(id ?? 0, { ok: true }));
      return;
    }
    this.send(ws, makeError(id ?? 0, AppErrorCodes.Unauthorized, "invalid token"));
    ws.close(4401, "unauthorized");
  }

  private handleLocal(ws: ServerWebSocket<ClientState>, id: string | number, method: string, params: unknown): void {
    if (method === "initialize") {
      this.send(ws, makeResponse(id, this.initializeResult()));
      return;
    }
    if (method === "session.list") {
      this.send(ws, makeResponse(id, { sessions: this.sessions.list() }));
      return;
    }
    if (method === "session.resume") {
      void this.handleSessionResume(ws, id, params);
      return;
    }
    if (method === "session.end") {
      this.handleSessionEnd(ws, id, params);
      return;
    }
    if (method === "files.search") {
      this.handleFilesSearch(ws, id, params);
      return;
    }
    this.send(ws, makeError(id, ErrorCodes.MethodNotFound, `unknown local method ${method}`));
  }

  private handleSessionEnd(ws: ServerWebSocket<ClientState>, id: string | number, params: unknown): void {
    const p = (params ?? {}) as Record<string, unknown>;
    const sessionId = typeof p.sessionId === "string" ? p.sessionId : "";
    if (!sessionId) {
      this.send(ws, makeError(id, ErrorCodes.InvalidParams, "sessionId is required"));
      return;
    }
    const existing = this.sessions.get(sessionId);
    if (!existing) {
      this.send(ws, makeError(id, ErrorCodes.InvalidParams, "session not found"));
      return;
    }
    this.sessions.markEnded(sessionId);
    this.events.clear(sessionId);
    this.send(ws, makeResponse(id, { ok: true }));
  }

  private async handleSessionResume(ws: ServerWebSocket<ClientState>, id: string | number, params: unknown): Promise<void> {
    const p = (params ?? {}) as Record<string, unknown>;
    const sessionId = typeof p.sessionId === "string" ? p.sessionId : "";
    if (!sessionId) {
      this.send(ws, makeError(id, ErrorCodes.InvalidParams, "sessionId is required"));
      return;
    }
    if (p.cursor !== undefined && !isValidCursor(p.cursor)) {
      this.send(ws, makeError(id, ErrorCodes.InvalidParams, "cursor must be a non-negative integer"));
      return;
    }
    const existing = this.sessions.get(sessionId);
    if (!existing) {
      this.send(ws, makeError(id, ErrorCodes.InvalidParams, "session not found"));
      return;
    }

    // No cursor → load the session fresh from the agent (original behaviour).
    // Cursor is only sent by clients that were previously connected and kept
    // track of their last event position.
    if (typeof p.cursor !== "number") {
      try {
        const acpParams = this.normalizeParams("session/load", { sessionId, mcpServers: p.mcpServers });
        const result = await this.acp.request("session/load", acpParams);
        this.sessions.markActive(sessionId);
        this.send(ws, makeResponse(id, this.withSessionConfig(sessionId, result)));
      } catch (err) {
        if (err instanceof RpcError) {
          this.sendError(ws, id, err.code, err.message);
          return;
        }
        const e = err as Error;
        this.sendError(ws, id, ErrorCodes.InternalError, e.message);
      }
      return;
    }

    const cursor = p.cursor;
    const replay = this.events.replay(sessionId, cursor);

    if (replay) {
      this.sessions.markActive(sessionId);
      this.send(ws, makeResponse(id, this.withSessionConfig(sessionId, {
        sessionId,
        recovery: "replay" satisfies RecoveryMode,
        events: replay.events,
        cursor: replay.latestCursor,
      })));
      return;
    }

    // The cursor is gone from the ring buffer. Fall back to a full snapshot from
    // the agent if it can replay history, otherwise admit the gap to the client.
    if (!this.agentSupportsLoadSession()) {
      this.sessions.markActive(sessionId);
      this.send(ws, makeResponse(id, this.withSessionConfig(sessionId, {
        sessionId,
        recovery: "live-only" satisfies RecoveryMode,
        events: [],
        cursor: this.events.latestCursor(sessionId),
        reason: "agent cannot replay session history; resuming from the live stream only",
      })));
      return;
    }

    try {
      const acpParams = this.normalizeParams("session/load", { sessionId, mcpServers: p.mcpServers });
      const result = await this.acp.request("session/load", acpParams);
      this.sessions.markActive(sessionId);
      this.send(ws, makeResponse(id, this.withSessionConfig(sessionId, {
        ...(typeof result === "object" && result !== null ? result : {}),
        sessionId,
        recovery: "snapshot" satisfies RecoveryMode,
        cursor: this.events.latestCursor(sessionId),
      })));
    } catch (err) {
      if (err instanceof RpcError) {
        this.sendError(ws, id, err.code, err.message);
        return;
      }
      const e = err as Error;
      this.sendError(ws, id, ErrorCodes.InternalError, e.message);
    }
  }

  private agentSupportsLoadSession(): boolean {
    const caps = this.agentInfo.agentCapabilities;
    if (typeof caps !== "object" || caps === null) return false;
    return (caps as { loadSession?: unknown }).loadSession === true;
  }

  private agentSupportsEmbeddedContext(): boolean {
    const caps = this.agentInfo.agentCapabilities;
    if (typeof caps !== "object" || caps === null) return false;
    const pc = (caps as { promptCapabilities?: unknown }).promptCapabilities;
    if (typeof pc !== "object" || pc === null) return false;
    return (pc as { embeddedContext?: unknown }).embeddedContext === true;
  }

  private handleFilesSearch(ws: ServerWebSocket<ClientState>, id: string | number, params: unknown): void {
    const p = (params ?? {}) as Record<string, unknown>;
    const sessionId = typeof p.sessionId === "string" ? p.sessionId : "";
    const query = typeof p.query === "string" ? p.query : "";
    if (!sessionId) {
      this.send(ws, makeError(id, ErrorCodes.InvalidParams, "sessionId is required"));
      return;
    }
    const session = this.sessions.get(sessionId);
    if (!session) {
      this.send(ws, makeError(id, ErrorCodes.InvalidParams, "session not found"));
      return;
    }
    const limit = typeof p.limit === "number" && Number.isInteger(p.limit) && p.limit > 0 ? p.limit : 20;
    const results = searchFiles(session.cwd, query, limit);
    this.send(ws, makeResponse(id, { files: results }));
  }

  private recordEvent(method: string, params: unknown): number | undefined {
    if (method !== "session/update") return undefined;
    const sessionId = this.sessionIdFromParams(params);
    if (!sessionId) return undefined;
    const cursor = this.events.record(sessionId, { method, params });
    this.pruneEventBuffers();
    return cursor;
  }

  /**
   * Agent→client request frames are buffered like session/update events so a
   * client that reconnects replays the pending approval card instead of losing
   * it (and never getting to answer — the agent would hang).
   */
  private recordAgentRequest(method: string, params: unknown, id: number | string): number | undefined {
    if (method !== "session/request_permission") return undefined;
    const sessionId = this.sessionIdFromParams(params);
    if (!sessionId) return undefined;
    const cursor = this.events.record(sessionId, { method, params, id });
    this.pruneEventBuffers();
    return cursor;
  }

  // --- Bark notification hooks -------------------------------------------------

  /**
   * A pending approval is announced once per request (dedup lives in the
   * notifier). The request is still relayed to clients for answering.
   */
  private onAgentRequest(method: string, params: unknown): void {
    if (method !== "session/request_permission") return;
    if (typeof params !== "object" || params === null) return;
    const p = params as { sessionId?: unknown; toolCall?: { toolCallId?: unknown; title?: unknown } };
    const sessionId = p.sessionId;
    const toolCall = p.toolCall;
    if (typeof sessionId !== "string" || !toolCall || typeof toolCall.toolCallId !== "string") return;
    const approval: ApprovalToolCall = {
      toolCallId: toolCall.toolCallId,
      ...(typeof toolCall.title === "string" ? { title: toolCall.title } : {}),
    };
    void this.notifier.notifyApproval(this.sessionRef(sessionId), approval);
  }

  /**
   * A tool call reaching a terminal state means the approval is resolved (or
   * will never be re-asked mid-turn); forget the dedup entry so a genuinely
   * re-asked request can notify again.
   */
  private onAgentNotification(method: string, params: unknown): void {
    if (method !== "session/update") return;
    if (typeof params !== "object" || params === null) return;
    const p = params as {
      sessionId?: unknown;
      update?: { sessionUpdate?: unknown; toolCallId?: unknown; status?: unknown };
    };
    const sessionId = p.sessionId;
    const update = p.update;
    if (typeof sessionId !== "string" || !update || update.sessionUpdate !== "tool_call_update") return;
    if (update.status === "completed" || update.status === "failed") {
      if (typeof update.toolCallId === "string") {
        this.notifier.resolveApproval(sessionId, update.toolCallId);
      }
    }
  }

  /**
   * A forwarded `session/prompt` resolving (or failing) ends the turn: push a
   * success/failure notification. Stale pending approvals of the turn are
   * forgotten regardless of the outcome.
   */
  private notifyTurnEnded(params: unknown, result: unknown, error: unknown): void {
    const sessionId = this.sessionIdFromParams(params);
    if (!sessionId) return;
    this.notifier.clearSession(sessionId);
    const outcome = classifyTurnEnd(result, error);
    if (outcome.kind === "none") return;
    void this.notifier.notifySessionEnded(this.sessionRef(sessionId), outcome);
  }

  private sessionRef(sessionId: string): SessionRef {
    const session = this.sessions.get(sessionId);
    return session ? { id: session.id, cwd: session.cwd } : { id: sessionId };
  }

  // --- end Bark notification hooks ---------------------------------------------

  // Buffers only earn their memory while a session can still be resumed. Ended
  // sessions are dropped so the footprint tracks live sessions, not the total
  // number of sessions this process has ever served.
  private pruneEventBuffers(): void {
    if (this.events.sessionCount() <= this.sessions.list().length) return;
    const resumable = this.sessions
      .list()
      .filter((s) => s.status !== "ended")
      .map((s) => s.id);
    this.events.retainOnly(resumable);
  }

  private sessionIdFromParams(params: unknown): string | undefined {
    if (typeof params !== "object" || params === null) return undefined;
    const p = params as { sessionId?: string };
    return typeof p.sessionId === "string" ? p.sessionId : undefined;
  }

  private initializeResult(): unknown {
    return {
      protocolVersion: this.agentInfo.protocolVersion,
      agentCapabilities: this.agentInfo.agentCapabilities,
      agentInfo: this.agentInfo.agentInfo,
      authMethods: [],
    };
  }

  private async forward(
    ws: ServerWebSocket<ClientState>,
    msg: { id?: number | string; method: string; params?: unknown },
  ): Promise<void> {
    try {
      const params = await this.expandParams(msg.method, msg.params);
      if (isNotification(msg)) {
        this.acp.notify(msg.method, params);
        return;
      }
      const result = await this.acp.request(msg.method, params);
      if (msg.method === "session/new") {
        this.trackNewSession(params, result);
      } else if (msg.method === "session/set_config_option") {
        this.cacheSetConfigOption(params, result);
      } else if (msg.method === "session/set_mode") {
        this.cacheSetMode(params);
      } else if (msg.method === "session/prompt") {
        const p = (params ?? {}) as { sessionId?: string };
        if (p.sessionId) this.sessions.touch(p.sessionId);
        this.notifyTurnEnded(params, result, undefined);
      }
      this.send(ws, makeResponse(msg.id!, result));
    } catch (err) {
      if (msg.method === "session/prompt") {
        this.notifyTurnEnded(msg.params, undefined, err);
      }
      if (err instanceof RpcError) {
        this.sendError(ws, msg.id ?? 0, err.code, err.message);
        return;
      }
      const e = err as Error;
      this.sendError(ws, msg.id ?? 0, ErrorCodes.InternalError, e.message);
    }
  }

  private trackNewSession(params: unknown, result: unknown): void {
    const p = (params ?? {}) as { cwd?: string };
    const r = (result ?? {}) as {
      sessionId?: string;
      configOptions?: unknown;
      modes?: unknown;
    };
    if (r.sessionId) {
      this.sessions.create(r.sessionId, p.cwd ?? "/");
      const patch: { configOptions?: unknown; modes?: unknown } = {};
      if (r.configOptions !== undefined) patch.configOptions = r.configOptions;
      if (r.modes !== undefined) patch.modes = r.modes;
      if (Object.keys(patch).length > 0) {
        this.sessions.setConfig(r.sessionId, patch);
      }
    }
  }

  private cacheSetConfigOption(params: unknown, result: unknown): void {
    const p = (params ?? {}) as { sessionId?: string };
    const r = (result ?? {}) as { configOptions?: unknown };
    if (typeof p.sessionId === "string" && r.configOptions !== undefined) {
      this.sessions.setConfig(p.sessionId, { configOptions: r.configOptions });
    }
  }

  private cacheSetMode(params: unknown): void {
    const p = (params ?? {}) as { sessionId?: string; modeId?: string };
    if (typeof p.sessionId !== "string" || typeof p.modeId !== "string") return;
    const prev = this.sessions.getConfig(p.sessionId);
    const modes = prev.modes;
    if (typeof modes === "object" && modes !== null) {
      this.sessions.setConfig(p.sessionId, {
        modes: { ...(modes as Record<string, unknown>), currentModeId: p.modeId },
      });
    }
  }

  /** Merges cached `configOptions` / `modes` into a resume payload. */
  private withSessionConfig(sessionId: string, result: unknown): unknown {
    const base = typeof result === "object" && result !== null ? (result as Record<string, unknown>) : {};
    const cached = this.sessions.getConfig(sessionId);
    const out: Record<string, unknown> = { ...base };
    // Prefer live agent fields on the load/snapshot result; otherwise use cache.
    if (out.configOptions === undefined && cached.configOptions !== undefined) {
      out.configOptions = cached.configOptions;
    }
    if (out.modes === undefined && cached.modes !== undefined) {
      out.modes = cached.modes;
    }
    // Refresh cache when the agent returned fresher values on load.
    if (out.configOptions !== undefined || out.modes !== undefined) {
      this.sessions.setConfig(sessionId, {
        ...(out.configOptions !== undefined ? { configOptions: out.configOptions } : {}),
        ...(out.modes !== undefined ? { modes: out.modes } : {}),
      });
    }
    return out;
  }

  private async expandParams(method: string, params: unknown): Promise<unknown> {
    const normalized = this.normalizeParams(method, params);
    if (method !== "session/prompt") return normalized;

    const p = (normalized ?? {}) as Record<string, unknown>;
    const sessionId = typeof p.sessionId === "string" ? p.sessionId : "";
    const prompt = p.prompt;
    if (!sessionId || !Array.isArray(prompt)) return normalized;

    const session = this.sessions.get(sessionId);
    if (!session) return normalized;

    const embeddedContext = this.agentSupportsEmbeddedContext();
    const expanded = await expandPrompt(prompt, session.cwd, embeddedContext);
    return { ...p, prompt: expanded };
  }

  private normalizeParams(method: string, params: unknown): unknown {
    if (!SESSION_LIFECYCLE_METHODS.has(method)) return params;
    if (typeof params !== "object" || params === null) return params;
    if (!("mcpServers" in params)) {
      return { ...params, mcpServers: [] };
    }
    return params;
  }

  private sendError(ws: ServerWebSocket<ClientState>, id: string | number, code: number, message: string): void {
    this.send(ws, makeError(id, code, message));
  }

  private broadcast(msg: unknown): void {
    const payload = JSON.stringify(msg);
    for (const ws of this.clients) {
      if (ws.data.authenticated && ws.readyState === 1) {
        ws.send(payload);
      }
    }
  }
}

function isValidCursor(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}