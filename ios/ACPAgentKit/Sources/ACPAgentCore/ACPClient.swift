import Combine
import Foundation

/// One fuzzy-match result from the companion's `files.search`. The path is
/// relative to the session's working directory — exactly what a `file_ref`
/// prompt block expects (issue #8).
public struct FileSearchResult: Decodable, Equatable, Sendable {
    public let path: String
    public let score: Int?

    enum CodingKeys: String, CodingKey {
        case path, score
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        score = try container.decodeIfPresent(Int.self, forKey: .score)
    }
}

public struct FileSearchResponse: Decodable, Equatable, Sendable {
    public let files: [FileSearchResult]

    enum CodingKeys: String, CodingKey {
        case files
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decodeIfPresent([FileSearchResult].self, forKey: .files) ?? []
    }
}

@MainActor
public final class ACPClient: ObservableObject {
    public enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var sessions: [SessionInfo] = []

    private let rpc: JsonRpcClient
    private let transport: any WebSocketTransport
    private let tokenStore: any TokenStore
    // Lazy so the `isConnected` closure can capture `self` — the conversation
    // actions' connection gate belongs to the client's lifecycle. First touched
    // in `init` by the change-signal forwarding below.
    private lazy var conversationStore: ConversationStore = ConversationStore(rpc: rpc) { [weak self] in
        self?.connectionState == .connected
    }
    private var conversationCancellable: AnyCancellable?

    public private(set) var endpoint: ServerEndpoint?
    public private(set) var token: String?

    public convenience init() {
        self.init(
            transport: URLSessionWebSocketTransport(),
            tokenStore: KeychainTokenStore()
        )
    }

    public init(transport: any WebSocketTransport, tokenStore: any TokenStore) {
        self.transport = transport
        self.rpc = JsonRpcClient(transport: transport)
        self.tokenStore = tokenStore
        self.rpc.onNotificationHandler = { [weak self] notification in
            Task { @MainActor in self?.handleNotification(notification) }
        }
        self.rpc.onRequestHandler = { [weak self] request in
            Task { @MainActor in self?.handleRequest(request) }
        }
        // `ConversationStore` is not a view seam (ADR-001/ADR-004), so its
        // change signal is forwarded through the client to keep views that
        // observe `conversation(for:)` via `@EnvironmentObject` re-rendering.
        conversationCancellable = conversationStore.objectWillChange.sink { [weak self] in
            MainActor.assumeIsolated {
                self?.objectWillChange.send()
            }
        }
    }

    /// Read-only access to a session's conversation state. A new, empty one is
    /// vended on first access so the view can subscribe immediately. The state
    /// itself is owned by the `ConversationStore`.
    public func conversation(for sessionId: String) -> SessionConversation {
        conversationStore.conversation(for: sessionId)
    }

    // MARK: - Connection lifecycle

    public func connect(endpoint: ServerEndpoint, token: String) async -> Bool {
        guard let url = endpoint.url else {
            connectionState = .failed("Invalid endpoint")
            return false
        }

        self.endpoint = endpoint
        self.token = token
        connectionState = .connecting

        do {
            try await rpc.connect(url: url)
        } catch {
            connectionState = .failed("Connection failed: \(error.localizedDescription)")
            return false
        }

        do {
            let ok = try await rpc.authenticate(token: token)
            if ok {
                try? tokenStore.saveToken(token, for: endpoint.displayString)
                tokenStore.saveEndpoint(endpoint.displayString)
                connectionState = .connected
                return true
            } else {
                connectionState = .failed("Authentication failed")
                await rpc.disconnect()
                return false
            }
        } catch let error as ConnectionError {
            switch error {
            case .unauthorized:
                connectionState = .failed("Invalid token")
            case .rpcError(_, let message):
                connectionState = .failed("Authentication error: \(message)")
            default:
                connectionState = .failed("Connection error: \(error.localizedDescription)")
            }
            await rpc.disconnect()
            return false
        } catch {
            connectionState = .failed("Connection error: \(error.localizedDescription)")
            await rpc.disconnect()
            return false
        }
    }

    public func reconnect() async {
        guard let endpoint = endpoint, let token = token else { return }
        await disconnect()
        _ = await connect(endpoint: endpoint, token: token)
    }

    /// Drops the socket but keeps transcripts, so a reconnect can resume each
    /// session from its last cursor instead of losing the screen.
    public func disconnect() async {
        await rpc.disconnect()
        connectionState = .disconnected
        sessions = []
    }

    public func signOut() async {
        if let endpoint = endpoint {
            try? tokenStore.deleteToken(for: endpoint.displayString)
            tokenStore.saveEndpoint("")
        }
        self.token = nil
        self.endpoint = nil
        await disconnect()
        conversationStore.clearAll()
    }

    // MARK: - Session list

    @discardableResult
    public func refreshSessions() async throws -> [SessionInfo] {
        guard connectionState == .connected else {
            throw ConnectionError.notConnected
        }
        let result = try await rpc.request("session.list")
        let list = try result.decode(SessionListResponse.self)
        sessions = list.sessions
        return list.sessions
    }

    // MARK: - Session conversation

    /// Resumes a session, replaying any buffered events the client has missed
    /// since its last known cursor. The resulting transcript and cursor are
    /// stored in the `ConversationStore`.
    @discardableResult
    public func resumeSession(id sessionId: String) async throws -> SessionResumeResponse {
        try await conversationStore.resumeSession(id: sessionId)
    }

    /// Sends a text prompt to the session. The message is optimistically
    /// inserted into the transcript as a local user bubble while the request is
    /// in flight.
    @discardableResult
    public func sendPrompt(sessionId: String, text: String) async throws -> String? {
        try await conversationStore.sendPrompt(sessionId: sessionId, text: text)
    }

    /// Sends a structured prompt (text + `file_ref` references) to the session.
    /// Reference blocks are expanded by the companion into content the agent
    /// reads (issue #8).
    @discardableResult
    public func sendPrompt(sessionId: String, prompt: [PromptBlock]) async throws -> String? {
        try await conversationStore.sendPrompt(sessionId: sessionId, prompt: prompt)
    }

    /// Issues a `session/cancel` notification to stop the current generation.
    /// Safe to call repeatedly; a no-op when nothing is in flight.
    public func cancelSession(id sessionId: String) async throws {
        try await conversationStore.cancelSession(id: sessionId)
    }

    /// Responds to a pending permission request with the chosen option. The
    /// card turns terminal and the receipt is sent back to the agent; a second
    /// answer to the same request is a silent no-op.
    public func respondToPermission(sessionId: String, requestId: JsonRpcId, option: PermissionOption) async throws {
        try await conversationStore.respondToPermission(sessionId: sessionId, requestId: requestId, option: option)
        // Keep the session-list pending badge in step with the resolution.
        Task { _ = try? await self.refreshSessions() }
    }

    // MARK: - File search (@ references)

    /// Fuzzy-searches the session's working directory via the companion's
    /// `files.search` (issue #8, built on #4). Paths are relative to the
    /// session cwd, ready to attach as `file_ref` prompt blocks.
    public func searchFiles(sessionId: String, query: String, limit: Int = 20) async throws -> [FileSearchResult] {
        guard connectionState == .connected else {
            throw ConnectionError.notConnected
        }
        let result = try await rpc.request("files.search", params: [
            "sessionId": AnyCodable(sessionId),
            "query": AnyCodable(query),
            "limit": AnyCodable(limit),
        ])
        let response = try result.decode(FileSearchResponse.self)
        return response.files
    }

    // MARK: - Persistence helpers

    public func loadPersistedCredentials() -> (endpoint: ServerEndpoint, token: String)? {
        guard let endpointStr = tokenStore.loadEndpoint(),
              !endpointStr.isEmpty,
              let endpoint = ServerEndpoint.parse(endpointStr),
              let token = try? tokenStore.loadToken(for: endpointStr),
              !token.isEmpty else {
            return nil
        }
        return (endpoint, token)
    }

    // MARK: - Notifications

    private func handleNotification(_ notification: JsonRpcNotification) {
        guard notification.method == "session/update" else { return }

        if let params = notification.params,
           let update = try? AnyCodable(params).decode(SessionUpdateNotification.self) {
            conversationStore.applySessionUpdate(update, cursor: notification.cursor)
        }

        // The session's `lastActiveAt` and status live on the list, so keep it
        // in step with the stream.
        Task {
            _ = try? await self.refreshSessions()
        }
    }

    /// Agent→client JSON-RPC requests (ADR-005): `session/request_permission`
    /// is decoded structurally and lands in the `ConversationStore` as a
    /// pending approval card. Anything else is not yet understood and ignored.
    private func handleRequest(_ request: JsonRpcRequest) {
        guard request.method == "session/request_permission",
              let params = request.params,
              var permission = try? AnyCodable(params).decode(PermissionRequest.self) else {
            return
        }
        permission.requestId = request.id
        conversationStore.applyPermissionRequest(permission)
        // The pending-approval badge on the session list follows the request.
        Task {
            _ = try? await self.refreshSessions()
        }
    }
}
