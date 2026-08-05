import { describe, expect, test } from "bun:test";
import { RingBuffer } from "../src/ring-buffer";

describe("RingBuffer", () => {
  test("push returns incrementing cursors starting from 0", () => {
    const rb = new RingBuffer<string>(10);
    expect(rb.push("a")).toBe(0);
    expect(rb.push("b")).toBe(1);
    expect(rb.push("c")).toBe(2);
  });

  test("size tracks number of items", () => {
    const rb = new RingBuffer<string>(10);
    expect(rb.size()).toBe(0);
    rb.push("a");
    expect(rb.size()).toBe(1);
    rb.push("b");
    expect(rb.size()).toBe(2);
  });

  test("capacity returns the max capacity", () => {
    const rb = new RingBuffer<string>(5);
    expect(rb.capacity()).toBe(5);
  });

  test("latestCursor returns -1 when empty", () => {
    const rb = new RingBuffer<string>(10);
    expect(rb.latestCursor()).toBe(-1);
  });

  test("latestCursor returns the cursor of the most recent push", () => {
    const rb = new RingBuffer<string>(10);
    rb.push("a");
    expect(rb.latestCursor()).toBe(0);
    rb.push("b");
    expect(rb.latestCursor()).toBe(1);
  });

  test("earliestCursor returns -1 when empty", () => {
    const rb = new RingBuffer<string>(10);
    expect(rb.earliestCursor()).toBe(-1);
  });

  test("earliestCursor returns 0 when not yet overflowed", () => {
    const rb = new RingBuffer<string>(10);
    rb.push("a");
    rb.push("b");
    expect(rb.earliestCursor()).toBe(0);
  });

  test("buffer evicts oldest when full, size stays at capacity", () => {
    const rb = new RingBuffer<string>(3);
    rb.push("a");
    rb.push("b");
    rb.push("c");
    expect(rb.size()).toBe(3);
    expect(rb.earliestCursor()).toBe(0);
    rb.push("d");
    expect(rb.size()).toBe(3);
    expect(rb.earliestCursor()).toBe(1);
    expect(rb.latestCursor()).toBe(3);
  });

  test("readSince returns all items from cursor+1 to latest when cursor is within buffer", () => {
    const rb = new RingBuffer<string>(10);
    rb.push("a");
    rb.push("b");
    rb.push("c");
    rb.push("d");
    const result = rb.readSince(1);
    expect(result).not.toBeNull();
    expect(result!.items).toEqual(["c", "d"]);
    expect(result!.from).toBe(2);
    expect(result!.to).toBe(3);
  });

  test("readSince with cursor of latest returns empty array", () => {
    const rb = new RingBuffer<string>(10);
    rb.push("a");
    rb.push("b");
    const result = rb.readSince(1);
    expect(result).not.toBeNull();
    expect(result!.items).toEqual([]);
    expect(result!.from).toBe(2);
    expect(result!.to).toBe(1);
  });

  test("readSince with cursor -1 returns all items", () => {
    const rb = new RingBuffer<string>(10);
    rb.push("a");
    rb.push("b");
    const result = rb.readSince(-1);
    expect(result).not.toBeNull();
    expect(result!.items).toEqual(["a", "b"]);
    expect(result!.from).toBe(0);
    expect(result!.to).toBe(1);
  });

  test("readSince returns null when cursor is before earliest (evicted)", () => {
    const rb = new RingBuffer<string>(3);
    rb.push("a");
    rb.push("b");
    rb.push("c");
    rb.push("d");
    rb.push("e");
    expect(rb.earliestCursor()).toBe(2);
    const result = rb.readSince(0);
    expect(result).toBeNull();
  });

  test("readSince returns null when cursor is way in the future", () => {
    const rb = new RingBuffer<string>(10);
    rb.push("a");
    const result = rb.readSince(99);
    expect(result).toBeNull();
  });

  test("readSince works correctly after overflow wraps around", () => {
    const rb = new RingBuffer<string>(3);
    for (let i = 0; i < 5; i++) {
      rb.push(`item_${i}`);
    }
    expect(rb.earliestCursor()).toBe(2);
    expect(rb.latestCursor()).toBe(4);
    const result = rb.readSince(2);
    expect(result).not.toBeNull();
    expect(result!.items).toEqual(["item_3", "item_4"]);
    expect(result!.from).toBe(3);
    expect(result!.to).toBe(4);
  });

  test("multiple overflows maintain correct cursors", () => {
    const rb = new RingBuffer<number>(5);
    for (let i = 0; i < 20; i++) {
      rb.push(i);
    }
    expect(rb.size()).toBe(5);
    expect(rb.earliestCursor()).toBe(15);
    expect(rb.latestCursor()).toBe(19);
    const result = rb.readSince(16);
    expect(result!.items).toEqual([17, 18, 19]);
    expect(result!.from).toBe(17);
    expect(result!.to).toBe(19);
  });

  test("readSince on empty buffer returns null", () => {
    const rb = new RingBuffer<string>(10);
    expect(rb.readSince(0)).toBeNull();
  });

  test("push with capacity 1 works correctly", () => {
    const rb = new RingBuffer<string>(1);
    expect(rb.push("a")).toBe(0);
    expect(rb.size()).toBe(1);
    expect(rb.push("b")).toBe(1);
    expect(rb.size()).toBe(1);
    expect(rb.earliestCursor()).toBe(1);
    expect(rb.latestCursor()).toBe(1);
    const result = rb.readSince(0);
    expect(result).not.toBeNull();
    expect(result!.items).toEqual(["b"]);
    expect(result!.from).toBe(1);
    expect(result!.to).toBe(1);
  });

  test("readSince returns null when cursor plus one is before earliest (gap exists)", () => {
    const rb = new RingBuffer<string>(3);
    rb.push("a");
    rb.push("b");
    rb.push("c");
    rb.push("d");
    rb.push("e");
    expect(rb.earliestCursor()).toBe(2);
    expect(rb.latestCursor()).toBe(4);
    expect(rb.readSince(0)).toBeNull();
    const result = rb.readSince(1);
    expect(result).not.toBeNull();
    expect(result!.items).toEqual(["c", "d", "e"]);
    expect(result!.from).toBe(2);
    expect(result!.to).toBe(4);
  });
});
