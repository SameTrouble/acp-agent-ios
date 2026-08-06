import Foundation
@testable import ACPAgentCore

/// A scriptable WebSocket stand-in. Tests register canned responses per method
/// and inspect the requests the client actually sent.
final class MockWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    var onMessage: ((String) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private(set) var connectedURL: URL?
    private var sentMessages: [String] = []
    private(set) var didDisconnect = false

    var connectError: Error?
    var sendError: Error?

    /// method -> handler producing the raw JSON string to reply with.
    var responders: [String: (JsonRpcId, [String: AnyCodable]?) -> String] = [:]

    func connect(url: URL, timeout: TimeInterval) async throws {
        if let connectError { throw connectError }
        connectedURL = url
    }

    func send(_ text: String) async throws {
        if let sendError { throw sendError }
        sentMessages.append(text)

        guard let data = text.data(using: .utf8),
              let request = try? JSONDecoder().decode(JsonRpcRequest.self, from: data) else {
            return
        }
        guard let responder = responders[request.method] else { return }
        let reply = responder(request.id, request.params)
        onMessage?(reply)
    }

    func disconnect() async {
        didDisconnect = true
    }

    func emit(_ raw: String) {
        onMessage?(raw)
    }

    func failConnection(_ error: Error?) {
        onDisconnect?(error)
    }

    func sentRequests() -> [JsonRpcRequest] {
        sentMessages.compactMap { text in
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(JsonRpcRequest.self, from: data)
        }
    }

    func methodsSent() -> [String] {
        sentRequests().map { $0.method }
    }
}

/// Non-Keychain token store so tests never touch the real keychain or
/// UserDefaults.
final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private var tokens: [String: String] = [:]
    private var endpoint: String?

    var saveTokenError: Error?

    init(tokens: [String: String] = [:], endpoint: String? = nil) {
        self.tokens = tokens
        self.endpoint = endpoint
    }

    func saveToken(_ token: String, for endpoint: String) throws {
        if let saveTokenError { throw saveTokenError }
        tokens[endpoint] = token
    }

    func loadToken(for endpoint: String) throws -> String? {
        tokens[endpoint]
    }

    func deleteToken(for endpoint: String) throws {
        tokens.removeValue(forKey: endpoint)
    }

    func loadEndpoint() -> String? {
        endpoint
    }

    func saveEndpoint(_ endpoint: String) {
        self.endpoint = endpoint
    }

    var storedTokens: [String: String] {
        tokens
    }
}

// MARK: - Response builders

func successResponse(id: JsonRpcId, resultJSON: String) -> String {
    let idPart: String
    switch id {
    case .number(let n): idPart = "\(n)"
    case .string(let s): idPart = "\"\(s)\""
    }
    return #"{"jsonrpc":"2.0","id":\#(idPart),"result":\#(resultJSON)}"#
}

func errorResponse(id: JsonRpcId, code: Int, message: String) -> String {
    let idPart: String
    switch id {
    case .number(let n): idPart = "\(n)"
    case .string(let s): idPart = "\"\(s)\""
    }
    return #"{"jsonrpc":"2.0","id":\#(idPart),"error":{"code":\#(code),"message":"\#(message)"}}"#
}

func sessionJSON(
    id: String,
    cwd: String,
    status: String = "active",
    hasPendingApproval: Bool = false,
    createdAt: Int = 1_700_000_000_000,
    lastActiveAt: Int = 1_700_000_000_000
) -> String {
    #"{"id":"\#(id)","cwd":"\#(cwd)","status":"\#(status)","hasPendingApproval":\#(hasPendingApproval),"createdAt":\#(createdAt),"lastActiveAt":\#(lastActiveAt)}"#
}
