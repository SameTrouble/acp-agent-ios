import { describe, expect, test } from "bun:test";
import {
  createFramedParser,
  encodeFrame,
  isNotification,
  isRequest,
  isResponse,
  makeError,
  makeRequest,
  makeResponse,
} from "../src/rpc";

describe("rpc framing", () => {
  test("createFramedParser splits newline-delimited frames", () => {
    const parse = createFramedParser();
    expect(parse('{"a":1}\n{"b":')).toEqual(['{"a":1}']);
    expect(parse('2}\n\n')).toEqual(['{"b":2}']);
  });

  test("parser preserves trailing partial line", () => {
    const parse = createFramedParser();
    expect(parse('{"x":1}\n{"y":')).toEqual(['{"x":1}']);
    expect(parse('2}\n')).toEqual(['{"y":2}']);
  });

  test("encodeFrame appends a newline", () => {
    expect(encodeFrame({ a: 1 })).toBe('{"a":1}\n');
  });
});

describe("rpc type guards", () => {
  test("isRequest detects a request with id", () => {
    expect(isRequest(makeRequest(1, "session/new", { cwd: "/x" }))).toBe(true);
    expect(isRequest({ jsonrpc: "2.0", method: "session/cancel" })).toBe(false);
  });

  test("isNotification detects a notification without id", () => {
    expect(isNotification({ jsonrpc: "2.0", method: "session/cancel" })).toBe(true);
    expect(isNotification(makeRequest(1, "session/new"))).toBe(false);
  });

  test("isResponse detects a response", () => {
    expect(isResponse(makeResponse(1, { ok: true }))).toBe(true);
    expect(isResponse(makeError(1, -32001, "nope"))).toBe(true);
    expect(isResponse(makeRequest(1, "x"))).toBe(false);
  });
});