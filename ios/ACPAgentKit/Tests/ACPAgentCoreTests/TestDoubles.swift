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

    /// Methods whose response is withheld until `release(_:)` is called, so a
    /// test can drive what happens while a request is still in flight.
    var deferredMethods: Set<String> = []
    private var deferred: [String: JsonRpcId] = [:]

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
        if deferredMethods.contains(request.method) {
            deferred[request.method] = request.id
            return
        }
        guard let responder = responders[request.method] else { return }
        let reply = responder(request.id, request.params)
        onMessage?(reply)
    }

    /// Deliver the withheld response for a previously deferred method.
    func release(_ method: String, resultJSON: String) {
        guard let id = deferred.removeValue(forKey: method) else { return }
        onMessage?(successResponse(id: id, resultJSON: resultJSON))
    }

    func releaseWithError(_ method: String, code: Int, message: String) {
        guard let id = deferred.removeValue(forKey: method) else { return }
        onMessage?(errorResponse(id: id, code: code, message: message))
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

    /// Frames sent without an `id` — i.e. JSON-RPC notifications.
    func sentNotifications() -> [JsonRpcNotification] {
        sentMessages.compactMap { text in
            guard let data = text.data(using: .utf8),
                  (try? JSONDecoder().decode(JsonRpcRequest.self, from: data)) == nil else { return nil }
            return try? JSONDecoder().decode(JsonRpcNotification.self, from: data)
        }
    }

    /// Frames sent with `result`/`error` — i.e. replies to agent→client
    /// requests (permission responses).
    func sentResponses() -> [JsonRpcResponse] {
        sentMessages.compactMap { text in
            guard let data = text.data(using: .utf8),
                  let response = try? JSONDecoder().decode(JsonRpcResponse.self, from: data),
                  response.result != nil || response.error != nil else { return nil }
            return response
        }
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

/// A `session/update` notification as the companion broadcasts it: the cursor
/// sits at the top level of the frame, not inside `params`.
func sessionUpdateNotificationJSON(sessionId: String, updateJSON: String, cursor: Int? = nil) -> String {
    let cursorPart = cursor.map { #","cursor":\#($0)"# } ?? ""
    return #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"\#(sessionId)","update":\#(updateJSON)}\#(cursorPart)}"#
}

func agentChunkJSON(_ text: String) -> String {
    #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\#(text)"}}"#
}

func toolCallJSON(id: String, title: String, kind: String = "read", status: String = "pending") -> String {
    #"{"sessionUpdate":"tool_call","toolCallId":"\#(id)","title":"\#(title)","kind":"\#(kind)","status":"\#(status)"}"#
}

func toolCallUpdateJSON(id: String, status: String) -> String {
    #"{"sessionUpdate":"tool_call_update","toolCallId":"\#(id)","status":"\#(status)"}"#
}

/// A `session/request_permission` frame as the companion broadcasts it (ADR-005
/// wire shape: envelope id outside `params`).
func permissionRequestJSON(sessionId: String, requestId: Int, toolTitle: String = "curl -s http://example.com") -> String {
    #"""
    {"jsonrpc":"2.0","id":\#(requestId),"method":"session/request_permission","params":{
      "sessionId":"\#(sessionId)",
      "toolCall":{"toolCallId":"call_\#(requestId)","title":"\#(toolTitle)","kind":"execute","status":"pending","locations":[{"path":"/etc/hosts"}],"rawInput":{"command":"\#(toolTitle)"}},
      "options":[
        {"optionId":"once","kind":"allow_once","name":"Allow once"},
        {"optionId":"always","kind":"allow_always","name":"Always allow"},
        {"optionId":"reject","kind":"reject_once","name":"Reject"}
      ]
    }}
    """#
}

/// The `params` part of a request_permission frame, for buffered replay events.
func permissionRequestParamsJSON(sessionId: String) -> String {
    #"""
    {"sessionId":"\#(sessionId)",
      "toolCall":{"toolCallId":"call_1","title":"curl -s http://example.com","kind":"execute","status":"pending","locations":[{"path":"/etc/hosts"}],"rawInput":{"command":"curl -s http://example.com"}},
      "options":[
        {"optionId":"once","kind":"allow_once","name":"Allow once"},
        {"optionId":"reject","kind":"reject_once","name":"Reject"}
      ]}
    """#
}
