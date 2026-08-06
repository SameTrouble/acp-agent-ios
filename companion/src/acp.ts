import { spawn, type Subprocess } from "bun";
import { createFramedParser, encodeFrame, isNotification, isRequest, isResponse, makeRequest, RpcError } from "./rpc";
import type { AgentConfig } from "./config";

export type NotificationHandler = (msg: { method: string; params?: unknown }) => void;

export type RequestHandler = (msg: { id: number | string; method: string; params?: unknown }) => void;

export interface InitializeResult {
  protocolVersion: number;
  agentCapabilities: Record<string, unknown>;
  agentInfo: Record<string, unknown>;
  authMethods: Array<{ id: string; name?: string; description?: string }>;
}

interface PendingRequest {
  resolve: (result: unknown) => void;
  reject: (err: Error) => void;
}

export interface AcpClientOptions {
  onNotification?: NotificationHandler;
  onRequest?: RequestHandler;
  onExit?: (code: number | null) => void;
  stderr?: (line: string) => void;
}

export class AcpClient {
  private proc: Subprocess;
  private nextId = 1;
  private pending = new Map<number, PendingRequest>();
  private writeChain: Promise<void> = Promise.resolve();
  private onNotification: NotificationHandler | undefined;
  private onRequest: RequestHandler | undefined;
  private onExit: ((code: number | null) => void) | undefined;
  private stderr: ((line: string) => void) | undefined;

  private constructor(proc: Subprocess, opts: AcpClientOptions) {
    this.proc = proc;
    this.onNotification = opts.onNotification;
    this.onRequest = opts.onRequest;
    this.onExit = opts.onExit;
    this.stderr = opts.stderr;
    this.proc.exited.then((code) => {
      this.rejectAll(new Error(`agent process exited with code ${code}`));
      this.onExit?.(code);
    });
  }

  static spawn(config: AgentConfig, opts: AcpClientOptions = {}): AcpClient {
    const proc = spawn({
      cmd: [config.command, ...config.args],
      stdout: "pipe",
      stdin: "pipe",
      stderr: "pipe",
    });

    const client = new AcpClient(proc, opts);
    client.readStdout();
    client.readStderr();
    return client;
  }

  setNotificationHandler(handler: NotificationHandler): void {
    this.onNotification = handler;
  }

  setRequestHandler(handler: RequestHandler): void {
    this.onRequest = handler;
  }

  private readStdout(): void {
    const parser = createFramedParser();
    const decoder = new TextDecoder();
    const reader = (this.proc.stdout as ReadableStream<Uint8Array>).getReader();
    const pump = async (): Promise<void> => {
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          const text = decoder.decode(value, { stream: true });
          for (const frame of parser(text)) {
            this.handleFrame(frame);
          }
        }
      } catch (err) {
        this.rejectAll(err instanceof Error ? err : new Error(String(err)));
      }
    };
    void pump();
  }

  private readStderr(): void {
    const parser = createFramedParser();
    const decoder = new TextDecoder();
    const reader = (this.proc.stderr as ReadableStream<Uint8Array>).getReader();
    const pump = async (): Promise<void> => {
      try {
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          const text = decoder.decode(value, { stream: true });
          for (const line of parser(text)) {
            this.stderr?.(line);
          }
        }
      } catch {
        // ignore stderr read errors
      }
    };
    void pump();
  }

  private handleFrame(frame: string): void {
    let msg: unknown;
    try {
      msg = JSON.parse(frame);
    } catch {
      return;
    }
    if (isResponse(msg)) {
      const id = typeof msg.id === "number" ? msg.id : Number(msg.id);
      const entry = this.pending.get(id);
      if (!entry) return;
      this.pending.delete(id);
      if (msg.error) {
        entry.reject(new RpcError(msg.error.code, msg.error.message, msg.error.data));
      } else {
        entry.resolve(msg.result);
      }
    } else if (isNotification(msg)) {
      this.onNotification?.({ method: msg.method, params: msg.params });
    } else if (isRequest(msg)) {
      this.onRequest?.({ id: msg.id as number | string, method: msg.method, params: msg.params });
    }
  }

  private write(frame: string): void {
    if (!this.proc.stdin) return;
    const sink = this.proc.stdin as unknown as { write(chunk: string): void };
    this.writeChain = this.writeChain
      .then(() => sink.write(frame))
      .catch(() => {
        // a failed write must not stop subsequent frames from being queued
      });
  }

  request<T = unknown>(method: string, params?: unknown): Promise<T> {
    const id = this.nextId++;
    this.write(encodeFrame(makeRequest(id, method, params)));
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
    });
  }

  notify(method: string, params?: unknown): void {
    this.write(encodeFrame({ jsonrpc: "2.0", method, ...(params !== undefined ? { params } : {}) }));
  }

  /**
   * Replies to an agent→client request (e.g. `session/request_permission`),
   * echoing the request's `id` (ADR-005 response expectations).
   */
  respond(id: number | string, result?: unknown): void {
    this.write(encodeFrame({ jsonrpc: "2.0", id, ...(result !== undefined ? { result } : {}) }));
  }

  /**
   * Replies with an error to an agent→client request. opencode treats any
   * error reply to `session/request_permission` as a rejection.
   */
  respondError(id: number | string, code: number, message: string): void {
    this.write(encodeFrame({ jsonrpc: "2.0", id, error: { code, message } }));
  }

  async initialize(): Promise<InitializeResult> {
    const result = (await this.request("initialize", {
      protocolVersion: 1,
      clientCapabilities: {},
      clientInfo: { name: "acp-agent-companion", version: "0.1.0" },
    })) as InitializeResult;
    return result;
  }

  private rejectAll(err: Error): void {
    for (const entry of this.pending.values()) {
      entry.reject(err);
    }
    this.pending.clear();
  }

  async close(): Promise<void> {
    try {
      this.proc.kill();
    } catch {
      // already dead
    }
    await this.proc.exited.catch(() => {});
  }
}