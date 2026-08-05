export class RingBuffer<T> {
  private items: T[];
  private cap: number;
  private start = 0;
  private count = 0;
  private seq = 0;

  constructor(capacity: number) {
    if (capacity <= 0) {
      throw new Error("capacity must be positive");
    }
    this.cap = capacity;
    this.items = new Array(capacity);
  }

  push(item: T): number {
    const cursor = this.seq++;
    if (this.count < this.cap) {
      this.items[(this.start + this.count) % this.cap] = item;
      this.count++;
    } else {
      this.items[this.start] = item;
      this.start = (this.start + 1) % this.cap;
    }
    return cursor;
  }

  readSince(cursor: number): { items: T[]; from: number; to: number } | null {
    if (this.count === 0) return null;

    const earliest = this.seq - this.count;
    const latest = this.seq - 1;

    if (cursor + 1 < earliest) return null;
    if (cursor > latest) return null;

    const from = cursor + 1;
    const to = latest;

    if (from > to) {
      return { items: [], from, to };
    }

    const result: T[] = [];
    for (let i = from; i <= to; i++) {
      const idx = (this.start + (i - earliest)) % this.cap;
      result.push(this.items[idx] as T);
    }

    return { items: result, from, to };
  }

  latestCursor(): number {
    return this.seq - 1;
  }

  earliestCursor(): number {
    if (this.count === 0) return -1;
    return this.seq - this.count;
  }

  size(): number {
    return this.count;
  }

  capacity(): number {
    return this.cap;
  }
}
