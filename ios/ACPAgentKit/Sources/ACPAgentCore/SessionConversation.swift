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
    public let recovery: RecoveryMode?
    public let events: [BufferedSessionEvent]
    public let cursor: Int?
    public let reason: String?
    /// Cached / agent-advertised config options for this session (issue #11).
    public let configOptions: [SessionConfigOption]
    /// Legacy modes fallback when the agent has no `configOptions`.
    public let modes: SessionModeState?

    enum CodingKeys: String, CodingKey {
        case sessionId, recovery, events, cursor, reason, configOptions, modes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        recovery = try container.decodeIfPresent(RecoveryMode.self, forKey: .recovery)
        events = try container.decodeIfPresent([BufferedSessionEvent].self, forKey: .events) ?? []
        cursor = try container.decodeIfPresent(Int.self, forKey: .cursor)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        if container.contains(.configOptions) {
            let list = try container.decode(SessionConfigOptionList.self, forKey: .configOptions)
            configOptions = list.options
        } else {
            configOptions = []
        }
        modes = try container.decodeIfPresent(SessionModeState.self, forKey: .modes)
    }
}

public struct PromptResponse: Decodable, Equatable, Sendable {
    public let stopReason: String?
}

/// One content block of a prompt sent via `session/prompt`. Text blocks go
/// through verbatim; `fileRef` blocks are expanded by the companion into
/// `resource` / `resource_link` content the agent can actually read
/// (issue #8, built on #4's `file_ref` expansion).
public enum PromptBlock: Equatable, Sendable {
    case text(String)
    case fileRef(path: String)

    /// The user-visible line for the optimistic transcript bubble.
    var displayText: String {
        switch self {
        case .text(let text): return text
        case .fileRef(let path): return "📎 \(path)"
        }
    }
}

/// Which suggestion panel the input bar shows for a piece of input text, and
/// what to filter by. `commands` comes from the session's
/// `available_commands_update`; `files` from the companion's `files.search`.
/// Kept in Core so the trigger semantics are unit-testable without a SwiftUI
/// host (ADR-001).
public enum PromptTrigger: Equatable, Sendable {
    case commands(query: String)
    case files(query: String)

    /// Parses input text into a trigger: a leading `/` opens the command panel
    /// (hidden once the query contains a space — i.e. after a command was
    /// picked and arguments follow); a leading `@` opens the file panel with
    /// the rest of the input as the fuzzy-search query.
    public static func parse(text: String) -> PromptTrigger? {
        if text.hasPrefix("/") {
            let query = String(text.dropFirst())
            guard !query.contains(where: \.isWhitespace) else { return nil }
            return .commands(query: query)
        }
        if text.hasPrefix("@") {
            return .files(query: String(text.dropFirst()))
        }
        return nil
    }

    /// Commands matching the trigger's query, or all commands for an empty
    /// query. A command matches when its name or description contains the
    /// query.
    public func filteredCommands(from available: [AvailableCommand]) -> [AvailableCommand] {
        guard case .commands(let query) = self, !query.isEmpty else { return available }
        return available.filter { command in
            command.name.localizedCaseInsensitiveContains(query)
                || (command.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
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
    /// The agent's slash-command directory for this session, replaced
    /// wholesale on every `available_commands_update` (ADR-005). Not part of
    /// the transcript — it feeds the input bar's `/` menu.
    public var availableCommands: [AvailableCommand] = []
    /// Session-level config options (`configOptions` / `config_option_update`).
    /// Prefer these over `modes` when both exist (issue #11).
    public var configOptions: [SessionConfigOption] = []
    /// Legacy modes state. Used only when `configOptions` is empty.
    public var modes: SessionModeState?

    public init() {}

    /// True once the agent has stopped streaming and no tool call is running.
    public var canSend: Bool { !isSending }

    /// Cancel only makes sense while the agent still has work to stop.
    public var canCancel: Bool { isSending || transcript.isGenerating }

    /// Select options the UI should render, in agent priority order. Falls
    /// back to a synthetic mode selector when only legacy `modes` exist.
    public var selectableConfigOptions: [SessionConfigOption] {
        Self.selectableConfigOptions(configOptions: configOptions, modes: modes)
    }

    /// Short label for the input-bar chip (prefer `category == "model"`).
    public var configChipSummary: String? {
        Self.chipSummary(configOptions: configOptions, modes: modes)
    }

    public static func selectableConfigOptions(
        configOptions: [SessionConfigOption],
        modes: SessionModeState?
    ) -> [SessionConfigOption] {
        if !configOptions.isEmpty {
            return configOptions.filter { $0.type == .select }
        }
        if let modes {
            return [modes.asSelectConfigOption()]
        }
        return []
    }

    public static func chipSummary(
        configOptions: [SessionConfigOption],
        modes: SessionModeState?
    ) -> String? {
        let selectable = selectableConfigOptions(configOptions: configOptions, modes: modes)
        guard !selectable.isEmpty else { return nil }
        if let model = selectable.first(where: { $0.category == "model" }) {
            return model.currentDisplayName
        }
        return selectable[0].currentDisplayName
    }

    mutating func apply(_ update: SessionUpdate, cursor incoming: Int?) {
        guard shouldApply(cursor: incoming) else { return }
        switch update {
        case .availableCommands(let commands):
            availableCommands = commands
        case .configOptions(let options):
            configOptions = options
        case .currentMode(let modeId):
            applyCurrentMode(modeId)
        default:
            transcript.apply(update)
        }
        advanceCursor(to: incoming)
    }

    /// Seeds config state from a resume / load response (companion cache or
    /// agent session setup fields).
    mutating func applySessionConfig(
        configOptions: [SessionConfigOption],
        modes: SessionModeState?
    ) {
        if !configOptions.isEmpty {
            self.configOptions = configOptions
        }
        if let modes {
            self.modes = modes
        }
    }

    mutating func replaceConfigOptions(_ options: [SessionConfigOption]) {
        configOptions = options
    }

    mutating func applyCurrentMode(_ modeId: String) {
        if var modes {
            modes.currentModeId = modeId
            self.modes = modes
        }
        // Keep a matching mode-category config option in sync when present.
        if let index = configOptions.firstIndex(where: { $0.category == "mode" || $0.id == "mode" }) {
            let option = configOptions[index]
            configOptions[index] = SessionConfigOption(
                id: option.id,
                name: option.name,
                description: option.description,
                category: option.category,
                type: option.type,
                currentValue: .string(modeId),
                options: option.options
            )
        }
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
