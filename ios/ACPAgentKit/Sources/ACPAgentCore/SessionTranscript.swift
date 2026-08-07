import Foundation

public enum TranscriptRole: String, Equatable, Sendable {
    case user
    case assistant
    case thought
}

public struct TranscriptMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let role: TranscriptRole
    public var text: String
    public var isComplete: Bool

    init(id: String, role: TranscriptRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
        self.isComplete = false
    }
}

public struct ToolCallCard: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var kind: ToolCallKind
    public var status: ToolCallStatus
    public var locations: [String]
    public var content: [String]
    /// File diffs ride the final `tool_call_update` (live-verified, issue #9),
    /// so a card usually starts with zero diffs and gains them on merge.
    public var diffs: [FileDiff]

    init(delta: ToolCallDelta) {
        self.id = delta.toolCallId
        self.title = delta.title ?? delta.toolCallId
        self.kind = delta.kind ?? .other
        self.status = delta.status ?? .pending
        self.locations = delta.locations ?? []
        self.content = delta.content ?? []
        self.diffs = delta.diffs ?? []
    }

    mutating func merge(_ delta: ToolCallDelta) {
        if let title = delta.title { self.title = title }
        if let kind = delta.kind { self.kind = kind }
        if let status = delta.status { self.status = status }
        if let locations = delta.locations { self.locations = locations }
        if let content = delta.content { self.content.append(contentsOf: content) }
        if let newDiffs = delta.diffs {
            for diff in newDiffs {
                if let index = self.diffs.firstIndex(where: { $0.path == diff.path }) {
                    self.diffs[index] = diff
                } else {
                    self.diffs.append(diff)
                }
            }
        }
    }
}

public enum TranscriptItem: Identifiable, Equatable, Sendable {
    case message(TranscriptMessage)
    case toolCall(ToolCallCard)
    case approval(PermissionCard)

    public var id: String {
        switch self {
        case .message(let message): return "msg:\(message.id)"
        case .toolCall(let card): return "tool:\(card.id)"
        case .approval(let card): return card.id
        }
    }
}

/// Accumulates a session's `session/update` stream into a render-ready
/// timeline. Chunks for the same speaker coalesce into one bubble; tool call
/// deltas merge into a single card keyed by `toolCallId`.
public struct SessionTranscript: Equatable, Sendable {
    public private(set) var items: [TranscriptItem] = []
    public private(set) var planEntries: [PlanEntry]?
    public private(set) var isGenerating: Bool = false

    private var nextMessageIndex: Int = 0
    private var toolCallIndexById: [String: Int] = [:]
    /// Index of a locally-echoed user bubble still waiting for the server to
    /// echo the same text back as `user_message_chunk`.
    private var pendingLocalUserIndex: Int?
    /// One approval card per permission request, keyed by the JSON-RPC id.
    private var approvalIndexById: [String: Int] = [:]

    public init() {}

    public var messages: [TranscriptMessage] {
        items.compactMap { if case .message(let message) = $0 { return message } else { return nil } }
    }

    public var toolCalls: [ToolCallCard] {
        items.compactMap { if case .toolCall(let card) = $0 { return card } else { return nil } }
    }

    public var approvalCards: [PermissionCard] {
        items.compactMap { if case .approval(let card) = $0 { return card } else { return nil } }
    }

    public mutating func apply(_ update: SessionUpdate) {
        switch update {
        case .agentMessageChunk(let block):
            appendChunk(block.text, role: .assistant)
        case .agentThoughtChunk(let block):
            appendChunk(block.text, role: .thought)
        case .userMessageChunk(let block):
            applyUserChunk(block.text)
        case .toolCall(let delta), .toolCallUpdate(let delta):
            applyToolCallDelta(delta)
        case .plan(let entries):
            planEntries = entries
            isGenerating = true
        case .availableCommands, .configOptions, .currentMode:
            // Session-level directories / config; consumed by the conversation
            // (see `SessionConversation.apply`) and rendered by the input bar.
            break
        case .unsupported:
            break
        }
    }

    /// Optimistically shows the text the user just sent, before the agent
    /// echoes it back as a `user_message_chunk`. The next user chunk from the
    /// server is merged into this bubble instead of creating a duplicate.
    public mutating func appendLocalUserMessage(_ text: String) {
        closeOpenMessage()
        nextMessageIndex += 1
        items.append(.message(TranscriptMessage(id: "m\(nextMessageIndex)", role: .user, text: text)))
        pendingLocalUserIndex = items.count - 1
        isGenerating = true
    }

    /// Adds a pending approval card for an agent permission request. A
    /// duplicate request id (re-broadcast or replay) keeps the first card.
    public mutating func applyApprovalRequest(_ request: PermissionRequest) {
        let key = request.requestId.wireKey
        guard approvalIndexById[key] == nil else { return }
        closeOpenMessage()
        // The agent is blocked waiting for the user's choice, not streaming.
        isGenerating = false
        approvalIndexById[key] = items.count
        items.append(.approval(PermissionCard(request: request)))
    }

    /// Transitions a pending card to a terminal state. Returns false when the
    /// request is unknown or already resolved — the caller must then send
    /// nothing (a second device may have answered first).
    @discardableResult
    public mutating func resolveApproval(requestId: JsonRpcId, state: PermissionState) -> Bool {
        guard let index = approvalIndexById[requestId.wireKey],
              case .approval(var card) = items[index],
              card.state == .pending else { return false }
        card.state = state
        items[index] = .approval(card)
        return true
    }

    /// Resets a terminal card back to pending. Used by the store to roll back
    /// an optimistic resolution whose receipt failed to send, so the user can
    /// try again.
    @discardableResult
    public mutating func revertApproval(requestId: JsonRpcId) -> Bool {
        guard let index = approvalIndexById[requestId.wireKey],
              case .approval(var card) = items[index],
              card.state.isTerminal else { return false }
        card.state = .pending
        items[index] = .approval(card)
        return true
    }

    public mutating func markGenerating() {
        isGenerating = true
    }

    /// The turn is over — no more chunks are expected, so every open bubble is
    /// final and the spinner stops.
    public mutating func markIdle() {
        closeOpenMessage()
        pendingLocalUserIndex = nil
        isGenerating = false
    }

    /// The server echoing back what we already showed locally must not create a
    /// second bubble; the first echo claims the pending optimistic one.
    private mutating func applyUserChunk(_ text: String) {
        if let index = pendingLocalUserIndex,
           case .message(var pending) = items[index],
           pending.text.hasPrefix(text) || text.hasPrefix(pending.text) {
            // Same message, possibly streaming in chunks — absorb into the
            // optimistic bubble and keep absorbing until a different role arrives.
            pending.text = text.count > pending.text.count ? text : pending.text
            items[index] = .message(pending)
            isGenerating = true
            return
        }
        // Not the same message — finalise the optimistic bubble and start a
        // fresh one for this chunk.
        if pendingLocalUserIndex != nil {
            closeOpenMessage()
            pendingLocalUserIndex = nil
        }
        appendChunk(text, role: .user)
    }

    private mutating func appendChunk(_ text: String, role: TranscriptRole) {
        isGenerating = true

        if case .message(var last) = items.last, last.role == role, !last.isComplete {
            last.text += text
            items[items.count - 1] = .message(last)
            return
        }

        closeOpenMessage()
        nextMessageIndex += 1
        items.append(.message(TranscriptMessage(id: "m\(nextMessageIndex)", role: role, text: text)))
    }

    private mutating func applyToolCallDelta(_ delta: ToolCallDelta) {
        isGenerating = true
        closeOpenMessage()

        if let index = toolCallIndexById[delta.toolCallId], case .toolCall(var card) = items[index] {
            card.merge(delta)
            items[index] = .toolCall(card)
            return
        }

        toolCallIndexById[delta.toolCallId] = items.count
        items.append(.toolCall(ToolCallCard(delta: delta)))
    }

    private mutating func closeOpenMessage() {
        guard case .message(var last) = items.last, !last.isComplete else { return }
        last.isComplete = true
        items[items.count - 1] = .message(last)
    }
}
