import type { Server, ServerWebSocket, WebSocketHandler } from "bun";
import type { AcpClient, InitializeResult } from "./acp";
import type { CompanionConfig } from "./config";
import type { SessionManager } from "./session";
import {
  AppErrorCodes,
  ErrorCodes,
  isNotification,
  isRequest,
  makeError,
  makeResponse,
  RpcError,
} from "./rpc";

interface ClientState {
  authenticated: boolean;
}

const LOCAL_METHODS = new Set(["auth", "initialize", "session.list", "session.resume", "session.end"]);

// opencode requires mcpServers on session lifecycle requests; inject an empty
// default so clients don't have to know.
const SESSION_LIFECYCLE_METHODS = new Set(["session/new", "session/load", "session/resume"]);

export interface CompanionServerOptions {
  config: CompanionConfig;
  acp: AcpClient;
  agentInfo: InitializeResult;
  sessions: SessionManager;
}

export class CompanionServer {
  private server: Server<ClientState> | undefined;
  private clients: ServerWebSocket<ClientState>[] = [];
  private config: CompanionConfig;
  private acp: AcpClient;
  private agentInfo: InitializeResult;
  private sessions: SessionManager;

  constructor(opts: CompanionServerOptions) {
    this.config = opts.config;
    this.acp = opts.acp;
    this.agentInfo = opts.agentInfo;
    this.sessions = opts.sessions;
  }

  async listen(): Promise<void> {
    this.acp.setNotificationHandler(({ method, params }) => {
      this.sessions.handleNotification(method, params);
      this.broadcast({ jsonrpc: "2.0", method, ...(params !== undefined ? { params } : {}) });
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
    this.send(ws, makeResponse(id, { ok: true }));
  }

  private async handleSessionResume(ws: ServerWebSocket<ClientState>, id: string | number, params: unknown): Promise<void> {
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
    try {
      const acpParams = this.normalizeParams("session/load", { sessionId, mcpServers: p.mcpServers });
      const result = await this.acp.request("session/load", acpParams);
      this.sessions.markActive(sessionId);
      this.send(ws, makeResponse(id, result));
    } catch (err) {
      if (err instanceof RpcError) {
        this.sendError(ws, id, err.code, err.message);
        return;
      }
      const e = err as Error;
      this.sendError(ws, id, ErrorCodes.InternalError, e.message);
    }
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
      const params = this.normalizeParams(msg.method, msg.params);
      if (isNotification(msg)) {
        this.acp.notify(msg.method, params);
        return;
      }
      const result = await this.acp.request(msg.method, params);
      if (msg.method === "session/new") {
        this.trackNewSession(params, result);
      } else if (msg.method === "session/prompt") {
        const p = (params ?? {}) as { sessionId?: string };
        if (p.sessionId) this.sessions.touch(p.sessionId);
      }
      this.send(ws, makeResponse(msg.id!, result));
    } catch (err) {
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
    const r = (result ?? {}) as { sessionId?: string };
    if (r.sessionId) {
      this.sessions.create(r.sessionId, p.cwd ?? "/");
    }
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