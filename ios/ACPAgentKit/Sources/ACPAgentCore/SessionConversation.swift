import Foundation

public enum RecoveryMode: String, Codable, Equatable, Sendable {
    case replay
    case snapshot
    case liveOnly = "live-only"
}

/// One buffered `session/update` frame from a `session.resume` replay. The
/// cursor sits alongside `method` and `params`, matching the live notification
/// shape the companion broadcasts.
public struct BufferedSessionEvent: Decodable, Equatable, Sendable {
    public let method: String
    public let params: SessionUpdateNotification?
    public let cursor: Int?

    enum CodingKeys: String, CodingKey {
        case method, params, cursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(String.self, forKey: .method)
        cursor = try container.decodeIfPresent(Int.self, forKey: .cursor)
        // Anything other than session/update carries no transcript payload we
        // know how to render, so it is dropped rather than failing the replay.
        params = method == "session/update"
            ? try? container.decodeIfPresent(SessionUpdateNotification.self, forKey: .params)
            : nil
    }
}

public struct SessionResumeResponse: Decodable, Equatable, Sendable {
    public let sessionId: String
    public let recovery: RecoveryMode
    public let events: [BufferedSessionEvent]
    public let cursor: Int?
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case sessionId, recovery, events, cursor, reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        recovery = try container.decode(RecoveryMode.self, forKey: .recovery)
        events = try container.decodeIfPresent([BufferedSessionEvent].self, forKey: .events) ?? []
        cursor = try container.decodeIfPresent(Int.self, forKey: .cursor)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

public struct PromptResponse: Decodable, Equatable, Sendable {
    public let stopReason: String?
}

/// Everything the session detail screen needs for one session: the rendered
/// transcript, how far through the event stream we are, and the in-flight state
/// of the send/cancel controls.
public struct SessionConversation: Equatable, Sendable {
    public var transcript = SessionTranscript()
    /// Highest event cursor applied. Sent back on `session.resume` so the
    /// companion can replay only what we missed.
    public var cursor: Int?
    public var recovery: RecoveryMode?
    public var recoveryReason: String?
    public var isResuming = false
    public var isSending = false
    public var errorMessage: String?

    public init() {}

    /// True once the agent has stopped streaming and no tool call is running.
    public var canSend: Bool { !isSending }

    /// Cancel only makes sense while the agent still has work to stop.
    public var canCancel: Bool { isSending || transcript.isGenerating }

    mutating func apply(_ update: SessionUpdate, cursor incoming: Int?) {
        guard shouldApply(cursor: incoming) else { return }
        transcript.apply(update)
        advanceCursor(to: incoming)
    }

    /// Cursors are monotonic per session; a lower one is a stale duplicate and
    /// must not rewind our resume position or double-apply events.
    mutating func advanceCursor(to incoming: Int?) {
        guard let incoming else { return }
        if let current = cursor, incoming <= current { return }
        cursor = incoming
    }

    private func shouldApply(cursor incoming: Int?) -> Bool {
        guard let incoming else { return true }
        guard let current = cursor else { return true }
        return incoming > current
    }
}
