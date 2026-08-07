import Foundation

public enum ToolCallKind: String, Codable, Equatable, Sendable {
    case read
    case edit
    case bash
    case search
    case browser
    case other
}

/// Status values follow the observed opencode wire (ADR-005): `in_progress`
/// and `failed` are real `tool_call_update` values — without them an in-flight
/// tool would decode to `.pending` forever and a rejected tool would never
/// show its failure.
public enum ToolCallStatus: String, Codable, Equatable, Sendable {
    case pending
    case running
    case inProgress = "in_progress"
    case completed
    case error
    case failed
}

public enum PlanEntryStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

public struct PlanEntry: Codable, Equatable, Sendable {
    public let content: String
    public let status: PlanEntryStatus

    public init(content: String, status: PlanEntryStatus) {
        self.content = content
        self.status = status
    }
}

public struct ToolCallDelta: Codable, Equatable, Sendable {
    public let toolCallId: String
    public let title: String?
    public let kind: ToolCallKind?
    public let status: ToolCallStatus?
    public let locations: [String]?
    public let content: [String]?
    /// Structurally decoded `{type: "diff"}` content blocks (issue #9): the
    /// per-file old/new texts an edit tool touched, with the unified diff
    /// computed client-side (live-verified on opencode 1.18.13 — diffs ride
    /// the final `tool_call_update`, not the opening `tool_call`).
    public let diffs: [FileDiff]?

    public init(toolCallId: String, title: String? = nil, kind: ToolCallKind? = nil, status: ToolCallStatus? = nil, locations: [String]? = nil, content: [String]? = nil, diffs: [FileDiff]? = nil) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.locations = locations
        self.content = content
        self.diffs = diffs
    }
}

public struct ContentBlock: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public static func text(_ value: String) -> ContentBlock {
        ContentBlock(text: value)
    }

    var displayText: String { text }
}

/// One slash command the agent advertises for the current session. Comes from
/// the live-observed `available_commands_update` wire variant (ADR-005): the
/// agent already filters out client-side commands (new session, cancel, theme,
/// …), so everything here is prompt-able via `session/prompt` with a
/// `/name args` text block.
public struct AvailableCommand: Codable, Equatable, Sendable {
    public let name: String
    public let description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

public enum SessionUpdate: Equatable, Sendable {
    case agentMessageChunk(ContentBlock)
    case agentThoughtChunk(ContentBlock)
    case userMessageChunk(ContentBlock)
    case toolCall(ToolCallDelta)
    case toolCallUpdate(ToolCallDelta)
    case plan([PlanEntry])
    /// The agent's current slash-command directory for this session
    /// (`available_commands_update`, live-verified in ADR-005). Replaces the
    /// previous list wholesale; the UI renders it as the `/` menu.
    case availableCommands([AvailableCommand])
    /// Complete session config state (`config_option_update`). Replaces the
    /// previous list wholesale; feeds the input-bar config chip (issue #11).
    case configOptions([SessionConfigOption])
    /// Legacy mode switch (`current_mode_update`). Updates `modes` when the
    /// agent only advertises the older modes API.
    case currentMode(modeId: String)
    /// Elicitation/probe note (issue #6): opencode's ACP mode does NOT appear
    /// to emit `elicitation/create` — all unrecognised `sessionUpdate`
    /// variants fall through here and are silently dropped. The UI renders
    /// nothing new for them. If a future agent version starts sending
    /// elicitation notifications, add a new case above and a card in the UI.
    case unsupported(String)

    var contentBlock: ContentBlock? {
        switch self {
        case .agentMessageChunk(let block), .agentThoughtChunk(let block), .userMessageChunk(let block):
            return block
        default:
            return nil
        }
    }
}

public struct SessionUpdateNotification: Codable, Equatable, Sendable {
    public let sessionId: String
    public let update: SessionUpdate
}

extension SessionUpdateNotification {
    enum CodingKeys: String, CodingKey {
        case sessionId
        case update
    }

    enum UpdateKeys: String, CodingKey {
        case sessionUpdate
        case content
        case toolCallId
        case title
        case kind
        case status
        case locations
        case entries
        case availableCommands
        case configOptions
        case modeId
        case currentModeId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)

        let updateContainer = try container.nestedContainer(keyedBy: UpdateKeys.self, forKey: .update)
        let variantRaw = try updateContainer.decode(String.self, forKey: .sessionUpdate)

        switch variantRaw {
        case "agent_message_chunk":
            let block = try Self.decodeContentBlock(from: updateContainer)
            update = .agentMessageChunk(block)
        case "agent_thought_chunk":
            let block = try Self.decodeContentBlock(from: updateContainer)
            update = .agentThoughtChunk(block)
        case "user_message_chunk":
            let block = try Self.decodeContentBlock(from: updateContainer)
            update = .userMessageChunk(block)
        case "tool_call":
            update = .toolCall(try Self.decodeToolCallDelta(from: updateContainer))
        case "tool_call_update":
            update = .toolCallUpdate(try Self.decodeToolCallDelta(from: updateContainer))
        case "plan":
            let entries = try updateContainer.decode([PlanEntry].self, forKey: .entries)
            update = .plan(entries)
        case "available_commands_update":
            let commands = try updateContainer.decode([AvailableCommand].self, forKey: .availableCommands)
            update = .availableCommands(commands)
        case "config_option_update":
            let list = try updateContainer.decode(SessionConfigOptionList.self, forKey: .configOptions)
            update = .configOptions(list.options)
        case "current_mode_update":
            // Spec field is `modeId`; older probes used `currentModeId`.
            if let modeId = try updateContainer.decodeIfPresent(String.self, forKey: .modeId) {
                update = .currentMode(modeId: modeId)
            } else if let modeId = try updateContainer.decodeIfPresent(String.self, forKey: .currentModeId) {
                update = .currentMode(modeId: modeId)
            } else {
                update = .unsupported(variantRaw)
            }
        default:
            update = .unsupported(variantRaw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        var updateContainer = container.nestedContainer(keyedBy: UpdateKeys.self, forKey: .update)

        switch update {
        case .agentMessageChunk:
            try updateContainer.encode("agent_message_chunk", forKey: .sessionUpdate)
        case .agentThoughtChunk:
            try updateContainer.encode("agent_thought_chunk", forKey: .sessionUpdate)
        case .userMessageChunk:
            try updateContainer.encode("user_message_chunk", forKey: .sessionUpdate)
        case .toolCall(let delta):
            try updateContainer.encode("tool_call", forKey: .sessionUpdate)
            try updateContainer.encode(delta.toolCallId, forKey: .toolCallId)
            try updateContainer.encodeIfPresent(delta.title, forKey: .title)
            try updateContainer.encodeIfPresent(delta.kind, forKey: .kind)
            try updateContainer.encodeIfPresent(delta.status, forKey: .status)
        case .toolCallUpdate(let delta):
            try updateContainer.encode("tool_call_update", forKey: .sessionUpdate)
            try updateContainer.encode(delta.toolCallId, forKey: .toolCallId)
            try updateContainer.encodeIfPresent(delta.title, forKey: .title)
            try updateContainer.encodeIfPresent(delta.kind, forKey: .kind)
            try updateContainer.encodeIfPresent(delta.status, forKey: .status)
        case .plan(let entries):
            try updateContainer.encode("plan", forKey: .sessionUpdate)
            try updateContainer.encode(entries, forKey: .entries)
        case .availableCommands(let commands):
            try updateContainer.encode("available_commands_update", forKey: .sessionUpdate)
            try updateContainer.encode(commands, forKey: .availableCommands)
        case .configOptions(let options):
            try updateContainer.encode("config_option_update", forKey: .sessionUpdate)
            try updateContainer.encode(options, forKey: .configOptions)
        case .currentMode(let modeId):
            try updateContainer.encode("current_mode_update", forKey: .sessionUpdate)
            try updateContainer.encode(modeId, forKey: .modeId)
        case .unsupported(let raw):
            try updateContainer.encode(raw, forKey: .sessionUpdate)
        }
    }

    private static func decodeContentBlock(from container: KeyedDecodingContainer<UpdateKeys>) throws -> ContentBlock {
        guard container.contains(.content) else {
            return ContentBlock(text: "")
        }
        let content = try container.decode(AnyCodable.self, forKey: .content)
        return ContentBlock(text: extractText(from: content))
    }

    private static func extractText(from anyCodable: AnyCodable) -> String {
        let value = anyCodable.value.base
        if let dict = value as? [String: AnyCodable] {
            if let type = (dict["type"]?.value.base as? String) {
                switch type {
                case "text":
                    return (dict["text"]?.value.base as? String) ?? ""
                case "resource":
                    if let resource = dict["resource"]?.value.base as? [String: AnyCodable],
                       let text = resource["text"]?.value.base as? String {
                        return text
                    }
                    return ""
                case "resource_link":
                    return (dict["name"]?.value.base as? String) ?? (dict["uri"]?.value.base as? String) ?? ""
                case "image":
                    return "[image]"
                default:
                    return ""
                }
            }
        }
        if let arr = value as? [AnyCodable] {
            return arr.map { extractText(from: $0) }.joined()
        }
        if let str = value as? String {
            return str
        }
        return ""
    }

    private static func decodeToolCallDelta(from container: KeyedDecodingContainer<UpdateKeys>) throws -> ToolCallDelta {
        let toolCallId = try container.decode(String.self, forKey: .toolCallId)
        let title = try container.decodeIfPresent(String.self, forKey: .title)
        let kindRaw = try container.decodeIfPresent(String.self, forKey: .kind)
        let statusRaw = try container.decodeIfPresent(String.self, forKey: .status)
        let locations = try decodeLocations(from: container)
        let (content, diffs) = try decodeToolCallContent(from: container)

        let kind: ToolCallKind?
        if let raw = kindRaw {
            kind = ToolCallKind(rawValue: raw) ?? .other
        } else {
            kind = nil
        }

        let status: ToolCallStatus?
        if let raw = statusRaw {
            status = ToolCallStatus(rawValue: raw) ?? .pending
        } else {
            status = nil
        }

        return ToolCallDelta(
            toolCallId: toolCallId,
            title: title,
            kind: kind,
            status: status,
            locations: locations,
            content: content,
            diffs: diffs
        )
    }

    private static func decodeLocations(from container: KeyedDecodingContainer<UpdateKeys>) throws -> [String]? {
        guard container.contains(.locations) else { return nil }
        let locationsArray = try container.decode([AnyCodable].self, forKey: .locations)
        return locationsArray.compactMap { loc in
            if let dict = loc.value.base as? [String: AnyCodable],
               let path = dict["path"]?.value.base as? String {
                return path
            }
            return nil
        }
    }

    /// Splits the content array into renderable text blocks and structurally
    /// decoded diff blocks (ADR-003: known wire variants decode even when the
    /// UI has no surface for them yet). `nil` when the whole key is absent.
    private static func decodeToolCallContent(from container: KeyedDecodingContainer<UpdateKeys>) throws -> (content: [String]?, diffs: [FileDiff]?) {
        guard container.contains(.content) else { return (nil, nil) }
        let contentArray = try container.decode([AnyCodable].self, forKey: .content)
        var texts: [String] = []
        var diffs: [FileDiff] = []
        for item in contentArray {
            guard let dict = item.value.base as? [String: AnyCodable],
                  let type = dict["type"]?.value.base as? String else { continue }
            switch type {
            case "content":
                if let inner = dict["content"]?.value.base as? [String: AnyCodable],
                   let innerType = inner["type"]?.value.base as? String,
                   innerType == "text",
                   let text = inner["text"]?.value.base as? String {
                    texts.append(text)
                }
            case "diff":
                if let diff = FileDiff.decode(from: item) {
                    diffs.append(diff)
                }
            default:
                break
            }
        }
        return (texts, diffs)
    }
}

extension ToolCallStatus {
    public var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .running: return "Running"
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        case .error: return "Error"
        case .failed: return "Failed"
        }
    }

    public var isTerminal: Bool {
        self == .completed || self == .error || self == .failed
    }

    /// SF Symbol for the status badge, shared by every card that renders a
    /// tool call (same convention as `ToolCallKind.systemImage`).
    public var systemImage: String {
        switch self {
        case .pending: return "clock"
        case .running: return "play.circle"
        case .inProgress: return "hourglass"
        case .completed: return "checkmark.circle.fill"
        case .error, .failed: return "xmark.circle.fill"
        }
    }
}

extension ToolCallKind {
    public var displayName: String {
        switch self {
        case .read: return "Read"
        case .edit: return "Edit"
        case .bash: return "Bash"
        case .search: return "Search"
        case .browser: return "Browser"
        case .other: return "Tool"
        }
    }

    public var systemImage: String {
        switch self {
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .bash: return "terminal"
        case .search: return "magnifyingglass"
        case .browser: return "globe"
        case .other: return "wrench.and.screwdriver"
        }
    }
}
