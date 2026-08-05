export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id?: number | string;
  method: string;
  params?: unknown;
}

export interface JsonRpcNotification {
  jsonrpc: "2.0";
  method: string;
  params?: unknown;
}

export interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number | string;
  result?: unknown;
  error?: JsonRpcError;
}

export interface JsonRpcError {
  code: number;
  message: string;
  data?: unknown;
}

export function isRequest(msg: unknown): msg is JsonRpcRequest {
  return (
    typeof msg === "object" &&
    msg !== null &&
    (msg as JsonRpcRequest).jsonrpc === "2.0" &&
    "method" in msg &&
    typeof (msg as JsonRpcRequest).method === "string" &&
    "id" in msg
  );
}

export function isNotification(msg: unknown): msg is JsonRpcNotification {
  return (
    typeof msg === "object" &&
    msg !== null &&
    (msg as JsonRpcNotification).jsonrpc === "2.0" &&
    "method" in msg &&
    typeof (msg as JsonRpcNotification).method === "string" &&
    !("id" in msg)
  );
}

export function isResponse(msg: unknown): msg is JsonRpcResponse {
  return (
    typeof msg === "object" &&
    msg !== null &&
    (msg as JsonRpcResponse).jsonrpc === "2.0" &&
    "id" in msg &&
    ("result" in msg || "error" in msg)
  );
}

export function makeRequest(id: number, method: string, params?: unknown): JsonRpcRequest {
  return { jsonrpc: "2.0", id, method, ...(params !== undefined ? { params } : {}) };
}

export function makeResponse(id: number | string, result?: unknown): JsonRpcResponse {
  return { jsonrpc: "2.0", id, ...(result !== undefined ? { result } : {}) };
}

export function makeError(id: number | string, code: number, message: string, data?: unknown): JsonRpcResponse {
  return { jsonrpc: "2.0", id, error: { code, message, ...(data !== undefined ? { data } : {}) } };
}

export const ErrorCodes = {
  ParseError: -32700,
  InvalidRequest: -32600,
  MethodNotFound: -32601,
  InvalidParams: -32602,
  InternalError: -32603,
} as const;

export const AppErrorCodes = {
  Unauthorized: -32001,
  NotConnected: -32002,
} as const;

export class RpcError extends Error {
  constructor(
    readonly code: number,
    message: string,
    readonly data?: unknown,
  ) {
    super(message);
    this.name = "RpcError";
  }
}

/**
 * Splits a raw stdio stream into newline-delimited frames. Returns the
 * complete frames and preserves any trailing partial line for the next call.
 */
export function createFramedParser() {
  let buffer = "";
  return function parseFrame(chunk: string): string[] {
    buffer += chunk;
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    return lines.filter((line) => line.trim().length > 0);
  };
}

export function encodeFrame(obj: unknown): string {
  return JSON.stringify(obj) + "\n";
}