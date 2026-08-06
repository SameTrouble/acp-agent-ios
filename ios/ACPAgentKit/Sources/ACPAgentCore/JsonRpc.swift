import Foundation

public enum JsonRpcId: Codable, Equatable, Sendable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .number(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected string or number for id")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }
}

public struct JsonRpcRequest: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: JsonRpcId
    public let method: String
    public let params: [String: AnyCodable]?

    public init(id: JsonRpcId, method: String, params: [String: AnyCodable]? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JsonRpcNotification: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: [String: AnyCodable]?
    public let cursor: Int?

    public init(method: String, params: [String: AnyCodable]? = nil, cursor: Int? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
        self.cursor = cursor
    }
}

public struct JsonRpcError: Codable, Equatable, Sendable, Error {
    public let code: Int
    public let message: String
    public let data: AnyCodable?

    public init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var isUnauthorized: Bool { code == -32001 }
    public var isNotConnected: Bool { code == -32002 }
}

public struct JsonRpcResponse: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let id: JsonRpcId
    public let result: AnyCodable?
    public let error: JsonRpcError?

    public var isSuccess: Bool { error == nil && result != nil }
}

public enum JsonRpcMessage: Codable, Equatable, Sendable {
    case request(JsonRpcRequest)
    case notification(JsonRpcNotification)
    case response(JsonRpcResponse)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasId = container.contains(.id)
        let hasResult = container.contains(.result)
        let hasError = container.contains(.error)
        let hasMethod = container.contains(.method)

        if hasResult || hasError {
            self = .response(try JsonRpcResponse(from: decoder))
        } else if hasId && hasMethod {
            self = .request(try JsonRpcRequest(from: decoder))
        } else if hasMethod {
            self = .notification(try JsonRpcNotification(from: decoder))
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown JSON-RPC message type")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .request(let req): try req.encode(to: encoder)
        case .notification(let notif): try notif.encode(to: encoder)
        case .response(let resp): try resp.encode(to: encoder)
        }
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params, result, error, cursor
    }
}

public struct AnyCodable: Codable, Equatable, Sendable {
    public let value: AnySendable

    public init(_ value: some Sendable) {
        self.value = AnySendable(value)
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = AnySendable(NSNull())
        } else if let bool = try? container.decode(Bool.self) {
            self.value = AnySendable(bool)
        } else if let int = try? container.decode(Int.self) {
            self.value = AnySendable(int)
        } else if let double = try? container.decode(Double.self) {
            self.value = AnySendable(double)
        } else if let string = try? container.decode(String.self) {
            self.value = AnySendable(string)
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = AnySendable(array)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = AnySendable(dict)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value.base {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [AnyCodable]:
            try container.encode(array)
        case let dict as [String: AnyCodable]:
            try container.encode(dict)
        default:
            let context = EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported value type")
            throw EncodingError.invalidValue(value.base, context)
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        lhs.value.base as AnyObject === rhs.value.base as AnyObject ||
        (try? JSONEncoder().encode(lhs)) == (try? JSONEncoder().encode(rhs))
    }
}

public final class AnySendable: @unchecked Sendable, Equatable {
    public let base: Any
    public init(_ value: some Sendable) {
        self.base = value
    }
    public static func == (lhs: AnySendable, rhs: AnySendable) -> Bool { false }
}
