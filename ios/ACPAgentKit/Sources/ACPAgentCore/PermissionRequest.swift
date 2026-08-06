import Foundation

// MARK: - session/request_permission wire types (ADR-005, live-verified)

/// One selectable option in a `session/request_permission` request. Kinds are
/// the observed opencode ones; an unrecognised kind decodes to `.rejectOnce`
/// because opencode treats any unknown choice as a rejection (ADR-005).
public enum PermissionKind: String, Codable, Equatable, Sendable {
    case allowOnce = "allow_once"
    case allowAlways = "allow_always"
    case rejectOnce = "reject_once"
}

public struct PermissionOption: Codable, Equatable, Identifiable, Sendable {
    public let optionId: String
    public let kind: PermissionKind
    public let name: String

    public var id: String { optionId }

    /// Approve-class options (`allow_*`) vs reject-class (`reject_*`). Drives
    /// the card's terminal state and the response outcome.
    public var isAllow: Bool { kind == .allowOnce || kind == .allowAlways }

    /// The ADR-005 `result` payload for this option: `selected` echoes the
    /// chosen `optionId`; a rejection has no `optionId`.
    public var wireResult: AnyCodable {
        let outcome: [String: AnyCodable]
        if isAllow {
            outcome = [
                "outcome": AnyCodable("selected"),
                "optionId": AnyCodable(optionId),
            ]
        } else {
            outcome = ["outcome": AnyCodable("rejected")]
        }
        return AnyCodable(["outcome": AnyCodable(outcome)])
    }

    public init(optionId: String, kind: PermissionKind, name: String) {
        self.optionId = optionId
        self.kind = kind
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case optionId
        case kind
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        optionId = try container.decode(String.self, forKey: .optionId)
        name = try container.decode(String.self, forKey: .name)
        let raw = try container.decode(String.self, forKey: .kind)
        kind = PermissionKind(rawValue: raw) ?? .rejectOnce
    }
}

/// The tool call a permission request gates: its title, kind (raw wire value —
/// `execute`/`read`/`edit`/`other`, distinct from `ToolCallKind`), locations,
/// original input, and — for edit requests — the diff preview (ADR-005).
public struct PermissionToolCall: Codable, Equatable, Sendable {
    public let toolCallId: String
    public let title: String?
    public let kind: String?
    public let locations: [String]
    public let rawInput: [String: AnyCodable]?
    /// Decoded `content` preview blocks: `diff` entries become "Diff: <path>"
    /// summaries, text entries keep their text (same shape as `ToolCallCard`).
    public let content: [String]

    public init(
        toolCallId: String,
        title: String? = nil,
        kind: String? = nil,
        locations: [String] = [],
        rawInput: [String: AnyCodable]? = nil,
        content: [String] = []
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.locations = locations
        self.rawInput = rawInput
        self.content = content
    }

    enum CodingKeys: String, CodingKey {
        case toolCallId
        case title
        case kind
        case locations
        case rawInput
        case content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        if container.contains(.locations) {
            let rawLocations = try container.decode([AnyCodable].self, forKey: .locations)
            locations = rawLocations.compactMap { loc in
                guard let dict = loc.value.base as? [String: AnyCodable],
                      let path = dict["path"]?.value.base as? String else { return nil }
                return path
            }
        } else {
            locations = []
        }
        rawInput = try container.decodeIfPresent([String: AnyCodable].self, forKey: .rawInput)
        if container.contains(.content) {
            let rawContent = try container.decode([AnyCodable].self, forKey: .content)
            content = rawContent.compactMap { Self.summariseContentBlock($0) }
        } else {
            content = []
        }
    }

    private static func summariseContentBlock(_ item: AnyCodable) -> String? {
        guard let dict = item.value.base as? [String: AnyCodable],
              let type = dict["type"]?.value.base as? String else { return nil }
        switch type {
        case "content":
            if let inner = dict["content"]?.value.base as? [String: AnyCodable],
               let innerType = inner["type"]?.value.base as? String,
               innerType == "text",
               let text = inner["text"]?.value.base as? String {
                return text
            }
            return nil
        case "diff":
            let path = (dict["path"]?.value.base as? String) ?? ""
            return "Diff: \(path)"
        default:
            return nil
        }
    }
}

extension PermissionToolCall {
    /// Best-effort "key: value" lines for the card body, in stable order.
    public var summaryLines: [String] {
        guard let rawInput, !rawInput.isEmpty else { return [] }
        return rawInput
            .map { key, value in "\(key): \(Self.stringify(value))" }
            .sorted()
    }

    private static func stringify(_ value: AnyCodable) -> String {
        switch value.value.base {
        case let bool as Bool: return bool ? "true" : "false"
        case let int as Int: return "\(int)"
        case let double as Double: return "\(double)"
        case let string as String: return string
        case is NSNull: return "null"
        default:
            return (try? JSONEncoder().encode(value))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }
}

/// A structured `session/request_permission` request (ADR-005). `requestId` is
/// the JSON-RPC envelope id, which sits outside `params`; `ACPClient` fills it
/// after decoding.
public struct PermissionRequest: Codable, Equatable, Sendable {
    public let sessionId: String
    public let toolCall: PermissionToolCall
    public let options: [PermissionOption]
    public var requestId: JsonRpcId = .number(0)

    public init(sessionId: String, toolCall: PermissionToolCall, options: [PermissionOption]) {
        self.sessionId = sessionId
        self.toolCall = toolCall
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case sessionId
        case toolCall
        case options
    }
}

// MARK: - Card state

public enum PermissionState: Equatable, Sendable {
    case pending
    case approved(optionId: String)
    case rejected

    public var isTerminal: Bool {
        if case .pending = self { return false }
        return true
    }
}

/// The render-ready approval card in the transcript: one per permission
/// request, keyed by its JSON-RPC id. State transitions are performed by the
/// `ConversationStore` (ADR-004).
public struct PermissionCard: Identifiable, Equatable, Sendable {
    public let id: String
    public let requestId: JsonRpcId
    public let toolCall: PermissionToolCall
    public let options: [PermissionOption]
    public var state: PermissionState

    init(request: PermissionRequest) {
        self.id = "perm:" + request.requestId.wireKey
        self.requestId = request.requestId
        self.toolCall = request.toolCall
        self.options = request.options
        self.state = .pending
    }
}
