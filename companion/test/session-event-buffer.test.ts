import { describe, expect, test } from "bun:test";
import { SessionEventBuffer } from "../src/session-event-buffer";

interface TestEvent {
  method: string;
  params: unknown;
}

function makeUpdate(sessionId: string, text: string): TestEvent {
  return { method: "session/update", params: { sessionId, update: { text } } };
}

describe("SessionEventBuffer", () => {
  test("record returns incrementing cursor per session", () => {
    const buf = new SessionEventBuffer(100);
    expect(buf.record("sess_a", makeUpdate("sess_a", "hello"))).toBe(0);
    expect(buf.record("sess_a", makeUpdate("sess_a", "world"))).toBe(1);
    expect(buf.record("sess_b", makeUpdate("sess_b", "hi"))).toBe(0);
    expect(buf.record("sess_b", makeUpdate("sess_b", "there"))).toBe(1);
  });

  test("latestCursor returns -1 for unknown session", () => {
    const buf = new SessionEventBuffer(100);
    expect(buf.latestCursor("sess_none")).toBe(-1);
  });

  test("latestCursor returns the latest cursor for a session", () => {
    const buf = new SessionEventBuffer(100);
    buf.record("sess_a", makeUpdate("sess_a", "a"));
    buf.record("sess_a", makeUpdate("sess_a", "b"));
    expect(buf.latestCursor("sess_a")).toBe(1);
  });

  test("replay returns events after the given cursor", () => {
    const buf = new SessionEventBuffer(100);
    buf.record("sess_a", makeUpdate("sess_a", "first"));
    buf.record("sess_a", makeUpdate("sess_a", "second"));
    buf.record("sess_a", makeUpdate("sess_a", "third"));

    const result = buf.replay("sess_a", 0);
    expect(result).not.toBeNull();
    const { events, latestCursor } = result!;
    expect(events.length).toBe(2);
    expect(events[0]!.params).toMatchObject({ update: { text: "second" } });
    expect(events[0]!.cursor).toBe(1);
    expect(events[1]!.params).toMatchObject({ update: { text: "third" } });
    expect(events[1]!.cursor).toBe(2);
    expect(latestCursor).toBe(2);
  });

  test("replay with cursor of latest returns empty events", () => {
    const buf = new SessionEventBuffer(100);
    buf.record("sess_a", makeUpdate("sess_a", "only"));
    const result = buf.replay("sess_a", 0);
    expect(result).not.toBeNull();
    expect(result!.events.length).toBe(0);
    expect(result!.latestCursor).toBe(0);
  });

  test("replay with cursor -1 returns all events", () => {
    const buf = new SessionEventBuffer(100);
    buf.record("sess_a", makeUpdate("sess_a", "a"));
    buf.record("sess_a", makeUpdate("sess_a", "b"));
    const result = buf.replay("sess_a", -1);
    expect(result).not.toBeNull();
    const events = result!.events;
    expect(events.length).toBe(2);
    expect(events[0]!.cursor).toBe(0);
    expect(events[1]!.cursor).toBe(1);
  });

  test("replay returns null for unknown session", () => {
    const buf = new SessionEventBuffer(100);
    expect(buf.replay("sess_none", 0)).toBeNull();
  });

  test("replay returns null when cursor is evicted (buffer overflow)", () => {
    const buf = new SessionEventBuffer(3);
    buf.record("sess_a", makeUpdate("sess_a", "1"));
    buf.record("sess_a", makeUpdate("sess_a", "2"));
    buf.record("sess_a", makeUpdate("sess_a", "3"));
    buf.record("sess_a", makeUpdate("sess_a", "4"));
    buf.record("sess_a", makeUpdate("sess_a", "5"));

    expect(buf.latestCursor("sess_a")).toBe(4);
    expect(buf.replay("sess_a", 0)).toBeNull();
    const result = buf.replay("sess_a", 2);
    expect(result).not.toBeNull();
    const events = result!.events;
    expect(events.length).toBe(2);
    expect(events[0]!.cursor).toBe(3);
    expect(events[1]!.cursor).toBe(4);
  });

  test("clear removes a session's buffer", () => {
    const buf = new SessionEventBuffer(100);
    buf.record("sess_a", makeUpdate("sess_a", "a"));
    buf.clear("sess_a");
    expect(buf.latestCursor("sess_a")).toBe(-1);
    expect(buf.replay("sess_a", 0)).toBeNull();
  });

  test("clear on unknown session is a no-op", () => {
    const buf = new SessionEventBuffer(100);
    expect(() => buf.clear("sess_none")).not.toThrow();
  });

  test("sessions have independent buffers", () => {
    const buf = new SessionEventBuffer(5);
    buf.record("sess_a", makeUpdate("sess_a", "a1"));
    buf.record("sess_a", makeUpdate("sess_a", "a2"));
    buf.record("sess_b", makeUpdate("sess_b", "b1"));

    expect(buf.latestCursor("sess_a")).toBe(1);
    expect(buf.latestCursor("sess_b")).toBe(0);

    expect(buf.replay("sess_a", -1)!.events.length).toBe(2);
    expect(buf.replay("sess_b", -1)!.events.length).toBe(1);
  });

  test("events include the original method and params plus cursor", () => {
    const buf = new SessionEventBuffer(100);
    const event = { method: "session/update", params: { sessionId: "sess_x", update: { type: "delta" } } };
    const cursor = buf.record("sess_x", event);

    const result = buf.replay("sess_x", -1);
    const first = result!.events[0]!;
    expect(first.method).toBe("session/update");
    expect(first.params).toMatchObject({ sessionId: "sess_x" });
    expect(first.cursor).toBe(cursor);
  });

  test("request frames keep their JSON-RPC id across record and replay", () => {
    const buf = new SessionEventBuffer(100);
    const cursor = buf.record("sess_x", {
      method: "session/request_permission",
      params: { sessionId: "sess_x", toolCall: { toolCallId: "call_1" } },
      id: 7,
    });
    const plain = buf.record("sess_x", { method: "session/update", params: { sessionId: "sess_x", update: { text: "a" } } });

    const result = buf.replay("sess_x", -1);
    expect(result).not.toBeNull();
    const [request, update] = result!.events;
    expect(request!.method).toBe("session/request_permission");
    expect(request!.id).toBe(7);
    expect(request!.cursor).toBe(cursor);
    expect(update!.method).toBe("session/update");
    expect(update!.id).toBeUndefined();
    expect(update!.cursor).toBe(plain);
  });

  test("buffer stays bounded regardless of how many events a session emits", () => {
    const buf = new SessionEventBuffer(10);
    for (let i = 0; i < 1000; i++) {
      buf.record("sess_a", makeUpdate("sess_a", `event_${i}`));
    }
    expect(buf.latestCursor("sess_a")).toBe(999);
    const result = buf.replay("sess_a", 989);
    expect(result).not.toBeNull();
    expect(result!.events.length).toBe(10);
    expect(buf.replay("sess_a", 500)).toBeNull();
  });

  test("retainOnly drops buffers for sessions not in the keep list", () => {
    const buf = new SessionEventBuffer(10);
    buf.record("sess_a", makeUpdate("sess_a", "a"));
    buf.record("sess_b", makeUpdate("sess_b", "b"));
    buf.record("sess_c", makeUpdate("sess_c", "c"));
    expect(buf.sessionCount()).toBe(3);

    buf.retainOnly(["sess_a", "sess_c"]);
    expect(buf.sessionCount()).toBe(2);
    expect(buf.latestCursor("sess_a")).toBe(0);
    expect(buf.latestCursor("sess_b")).toBe(-1);
    expect(buf.latestCursor("sess_c")).toBe(0);
  });
});
