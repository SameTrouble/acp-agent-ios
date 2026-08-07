import Foundation

/// One selectable value under a `select` session config option
/// (`session-config-options` wire).
public struct SessionConfigOptionValue: Codable, Equatable, Sendable {
    public let value: String
    public let name: String
    public let description: String?

    public init(value: String, name: String, description: String? = nil) {
        self.value = value
        self.name = name
        self.description = description
    }
}

/// Wire `type` for a config option. Clients ignore unrecognised types
/// (Agent keeps its default). `boolean` is only valid when the Client
/// advertised support — this client does not, so booleans are skipped.
public enum SessionConfigOptionType: String, Codable, Equatable, Sendable {
    case select
}

/// Current value of a config option. Select options carry a string id;
/// boolean is decoded for forward-compat but filtered out before storage.
public enum SessionConfigOptionCurrentValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

extension SessionConfigOptionCurrentValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else {
            throw DecodingError.typeMismatch(
                SessionConfigOptionCurrentValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or bool")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// One session-level configuration option advertised by the Agent
/// (`configOptions` on session setup / `config_option_update`).
public struct SessionConfigOption: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    /// Semantic UX hint (`model`, `mode`, …). Must not gate correctness.
    public let category: String?
    public let type: SessionConfigOptionType
    public let currentValue: SessionConfigOptionCurrentValue
    public let options: [SessionConfigOptionValue]?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        category: String? = nil,
        type: SessionConfigOptionType,
        currentValue: SessionConfigOptionCurrentValue,
        options: [SessionConfigOptionValue]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.type = type
        self.currentValue = currentValue
        self.options = options
    }

    /// Display name for the current select value, falling back to the raw id.
    public var currentDisplayName: String {
        guard let current = currentValue.stringValue else { return name }
        if let match = options?.first(where: { $0.value == current }) {
            return match.name
        }
        return current
    }
}

extension SessionConfigOption: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, description, category, type, currentValue, options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        type = try container.decode(SessionConfigOptionType.self, forKey: .type)
        currentValue = try container.decode(SessionConfigOptionCurrentValue.self, forKey: .currentValue)
        options = try container.decodeIfPresent([SessionConfigOptionValue].self, forKey: .options)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encode(type, forKey: .type)
        try container.encode(currentValue, forKey: .currentValue)
        try container.encodeIfPresent(options, forKey: .options)
    }

    /// Decodes an array, dropping entries whose `type` this client does not
    /// support (unknown / unadvertised boolean), so Agents keep defaults.
    public static func decodeSupported(from decoder: Decoder) throws -> [SessionConfigOption] {
        var container = try decoder.unkeyedContainer()
        var result: [SessionConfigOption] = []
        while !container.isAtEnd {
            let option = try container.decode(FlexibleSessionConfigOption.self)
            if let supported = option.supported {
                result.append(supported)
            }
        }
        return result
    }
}

/// Intermediate decode that tolerates unknown `type` values without failing
/// the whole array.
private struct FlexibleSessionConfigOption: Decodable {
    let supported: SessionConfigOption?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SessionConfigOption.CodingKeys.self)
        let typeRaw = try container.decode(String.self, forKey: .type)
        guard let type = SessionConfigOptionType(rawValue: typeRaw) else {
            supported = nil
            // Drain remaining keys so the container doesn't complain.
            _ = try? container.decodeIfPresent(String.self, forKey: .id)
            return
        }
        supported = SessionConfigOption(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            category: try container.decodeIfPresent(String.self, forKey: .category),
            type: type,
            currentValue: try container.decode(SessionConfigOptionCurrentValue.self, forKey: .currentValue),
            options: try container.decodeIfPresent([SessionConfigOptionValue].self, forKey: .options)
        )
    }
}

/// Wrapper so `[SessionConfigOption]` decoding skips unsupported types.
public struct SessionConfigOptionList: Decodable, Equatable, Sendable {
    public let options: [SessionConfigOption]

    public init(options: [SessionConfigOption]) {
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        options = try SessionConfigOption.decodeSupported(from: decoder)
    }
}

// MARK: - Legacy session modes

/// One mode from the older `modes` session-setup field.
public struct SessionMode: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// Legacy mode state (`modes` on session setup). Prefer `configOptions`
/// when both are present; synthesize a single select when only modes exist.
public struct SessionModeState: Codable, Equatable, Sendable {
    public var currentModeId: String
    public let availableModes: [SessionMode]

    public init(currentModeId: String, availableModes: [SessionMode]) {
        self.currentModeId = currentModeId
        self.availableModes = availableModes
    }

    public var currentDisplayName: String {
        availableModes.first(where: { $0.id == currentModeId })?.name ?? currentModeId
    }

    /// Synthetic select option so the UI renders modes through the same
    /// generic config path (issue #11).
    public func asSelectConfigOption() -> SessionConfigOption {
        SessionConfigOption(
            id: "mode",
            name: "Mode",
            category: "mode",
            type: .select,
            currentValue: .string(currentModeId),
            options: availableModes.map {
                SessionConfigOptionValue(value: $0.id, name: $0.name, description: $0.description)
            }
        )
    }
}

/// Response body for `session/set_config_option`.
public struct SetConfigOptionResponse: Decodable, Equatable, Sendable {
    public let configOptions: [SessionConfigOption]

    enum CodingKeys: String, CodingKey {
        case configOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.configOptions) {
            let list = try container.decode(SessionConfigOptionList.self, forKey: .configOptions)
            configOptions = list.options
        } else {
            configOptions = []
        }
    }
}
