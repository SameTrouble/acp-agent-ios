import { RingBuffer } from "./ring-buffer";

export interface BufferedEvent {
  method: string;
  params: unknown;
  cursor: number;
}

interface BufferEntry {
  method: string;
  params: unknown;
}

export class SessionEventBuffer {
  private buffers = new Map<string, RingBuffer<BufferEntry>>();
  private capacity: number;

  constructor(capacity: number) {
    this.capacity = capacity;
  }

  record(sessionId: string, event: { method: string; params: unknown }): number {
    let buf = this.buffers.get(sessionId);
    if (!buf) {
      buf = new RingBuffer<BufferEntry>(this.capacity);
      this.buffers.set(sessionId, buf);
    }
    return buf.push({ method: event.method, params: event.params });
  }

  replay(sessionId: string, cursor: number): { events: BufferedEvent[]; latestCursor: number } | null {
    const buf = this.buffers.get(sessionId);
    if (!buf) return null;

    const result = buf.readSince(cursor);
    if (!result) return null;

    const events: BufferedEvent[] = result.items.map((item, i) => ({
      method: item.method,
      params: item.params,
      cursor: result.from + i,
    }));

    return { events, latestCursor: result.to };
  }

  latestCursor(sessionId: string): number {
    const buf = this.buffers.get(sessionId);
    if (!buf) return -1;
    return buf.latestCursor();
  }

  clear(sessionId: string): void {
    this.buffers.delete(sessionId);
  }

  /**
   * Drops the buffers of sessions the caller no longer considers recoverable,
   * so that memory stays bounded by the number of live sessions rather than by
   * the number of sessions the process has ever seen.
   */
  retainOnly(sessionIds: Iterable<string>): void {
    const keep = new Set(sessionIds);
    for (const id of this.buffers.keys()) {
      if (!keep.has(id)) this.buffers.delete(id);
    }
  }

  sessionCount(): number {
    return this.buffers.size;
  }
}
