import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

export type SessionStatus = "active" | "ended" | "interrupted";

export interface SessionInfo {
  id: string;
  cwd: string;
  status: SessionStatus;
  hasPendingApproval: boolean;
  createdAt: number;
  lastActiveAt: number;
}

interface SessionStore {
  sessions: SessionInfo[];
}

export class SessionManager {
  private sessions = new Map<string, SessionInfo>();
  private persistencePath: string;

  constructor(persistencePath: string) {
    this.persistencePath = persistencePath;
  }

  load(): void {
    let raw: string;
    try {
      raw = readFileSync(this.persistencePath, "utf8");
    } catch {
      return;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return;
    }
    if (typeof parsed !== "object" || parsed === null) return;
    const store = parsed as SessionStore;
    if (!Array.isArray(store.sessions)) return;

    for (const s of store.sessions) {
      if (!s || typeof s !== "object") continue;
      const info = s as unknown as Record<string, unknown>;
      const id = info.id;
      const cwd = info.cwd;
      if (typeof id !== "string" || typeof cwd !== "string") continue;
      const session: SessionInfo = {
        id,
        cwd,
        status: info.status === "ended" ? "ended" : "interrupted",
        hasPendingApproval: info.hasPendingApproval === true,
        createdAt: typeof info.createdAt === "number" ? info.createdAt : Date.now(),
        lastActiveAt: typeof info.lastActiveAt === "number" ? info.lastActiveAt : Date.now(),
      };
      this.sessions.set(id, session);
    }
  }

  list(): SessionInfo[] {
    return Array.from(this.sessions.values()).sort((a, b) => b.lastActiveAt - a.lastActiveAt);
  }

  create(id: string, cwd: string): SessionInfo {
    const now = Date.now();
    const session: SessionInfo = {
      id,
      cwd,
      status: "active",
      hasPendingApproval: false,
      createdAt: now,
      lastActiveAt: now,
    };
    this.sessions.set(id, session);
    this.save();
    return session;
  }

  get(id: string): SessionInfo | undefined {
    return this.sessions.get(id);
  }

  markActive(id: string): void {
    const s = this.sessions.get(id);
    if (!s) return;
    s.status = "active";
    s.lastActiveAt = Date.now();
    this.save();
  }

  markEnded(id: string): void {
    const s = this.sessions.get(id);
    if (!s) return;
    s.status = "ended";
    s.hasPendingApproval = false;
    s.lastActiveAt = Date.now();
    this.save();
  }

  markInterrupted(id: string): void {
    const s = this.sessions.get(id);
    if (!s) return;
    if (s.status === "active") {
      s.status = "interrupted";
    }
    this.save();
  }

  markAllActiveInterrupted(): void {
    for (const s of this.sessions.values()) {
      if (s.status === "active") {
        s.status = "interrupted";
      }
    }
    this.save();
  }

  setPendingApproval(id: string, pending: boolean): void {
    const s = this.sessions.get(id);
    if (!s) return;
    s.hasPendingApproval = pending;
    s.lastActiveAt = Date.now();
    this.save();
  }

  touch(id: string): void {
    const s = this.sessions.get(id);
    if (!s) return;
    s.lastActiveAt = Date.now();
    this.save();
  }

  handleNotification(method: string, params: unknown): void {
    if (method !== "session/update") return;
    if (typeof params !== "object" || params === null) return;
    const p = params as { sessionId?: string; update?: { sessionUpdate?: string; [k: string]: unknown } };
    const sessionId = p.sessionId;
    if (!sessionId) return;

    const s = this.sessions.get(sessionId);
    if (!s) return;

    s.lastActiveAt = Date.now();
    this.save();
  }

  private save(): void {
    try {
      const store: SessionStore = { sessions: Array.from(this.sessions.values()) };
      mkdirSync(dirname(this.persistencePath), { recursive: true });
      writeFileSync(this.persistencePath, JSON.stringify(store, null, 2), "utf8");
    } catch {
      // persistence failures should not crash the server
    }
  }
}
