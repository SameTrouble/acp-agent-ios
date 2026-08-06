import Foundation

public enum RecoveryMode: String, Codable, Equatable, Sendable {
    case replay
    case snapshot
    case liveOnly = "live-only"
}

/// One buffered frame from a `session.resume` replay. The cursor sits alongside
/// `method` and `params`, matching the live notification shape the companion
/// broadcasts. Agent→client request frames (`session/request_permission`) are
/// buffered too, carrying their JSON-RPC `id` so a reconnecting client can
/// still answer them.
public struct BufferedSessionEvent: Decodable, Equatable, Sendable {
    public let method: String
    public let params: SessionUpdateNotification?
    public let request: PermissionRequest?
    public let cursor: Int?

    enum CodingKeys: String, CodingKey {
        case method, params, cursor, id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(String.self, forKey: .method)
        cursor = try container.decodeIfPresent(Int.self, forKey: .cursor)
        if method == "session/update" {
            params = try? container.decodeIfPresent(SessionUpdateNotification.self, forKey: .params)
            request = nil
        } else if method == "session/request_permission",
                  var decoded = try? container.decodeIfPresent(PermissionRequest.self, forKey: .params),
                  let id = try? container.decodeIfPresent(JsonRpcId.self, forKey: .id) {
            decoded.requestId = id
            request = decoded
            params = nil
        } else {
            // Anything else carries no transcript payload we know how to
            // render, so it is dropped rather than failing the replay.
            params = nil
            request = nil
        }
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

    /// Applies a replayed or live permission request. Request frames share the
    /// session's cursor stream, so the same monotonic guard applies.
    mutating func applyApprovalRequest(_ request: PermissionRequest, cursor incoming: Int?) {
        guard shouldApply(cursor: incoming) else { return }
        transcript.applyApprovalRequest(request)
        advanceCursor(to: incoming)
    }

    /// Transitions the matching approval card to a terminal state.
    @discardableResult
    mutating func resolveApproval(requestId: JsonRpcId, state: PermissionState) -> Bool {
        transcript.resolveApproval(requestId: requestId, state: state)
    }

    /// Resets the matching card back to pending (rollback of a failed send).
    @discardableResult
    mutating func revertApproval(requestId: JsonRpcId) -> Bool {
        transcript.revertApproval(requestId: requestId)
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
