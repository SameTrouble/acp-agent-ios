import Foundation

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
    @Published public private(set) var conversations: [String: SessionConversation] = [:]

    private let rpc: JsonRpcClient
    private let transport: any WebSocketTransport
    private let tokenStore: any TokenStore

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
    }

    /// Read-only access to a session's conversation state. A new, empty one is
    /// vended on first access so the view can subscribe immediately.
    public func conversation(for sessionId: String) -> SessionConversation {
        conversations[sessionId] ?? SessionConversation()
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
        conversations = [:]
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
    /// stored in `conversations[sessionId]`.
    @discardableResult
    public func resumeSession(id sessionId: String) async throws -> SessionResumeResponse {
        guard connectionState == .connected else {
            throw ConnectionError.notConnected
        }

        var params: [String: AnyCodable] = ["sessionId": AnyCodable(sessionId)]
        if let cursor = conversation(for: sessionId).cursor {
            params["cursor"] = AnyCodable(cursor)
        }

        mutateConversation(sessionId) { $0.isResuming = true }
        defer { mutateConversation(sessionId) { $0.isResuming = false } }

        let result = try await rpc.request("session.resume", params: params)
        let response = try result.decode(SessionResumeResponse.self)

        mutateConversation(sessionId) { conv in
            conv.recovery = response.recovery
            conv.recoveryReason = response.reason

            for event in response.events {
                guard let update = event.params else { continue }
                conv.apply(update.update, cursor: event.cursor)
            }
            if let cursor = response.cursor {
                conv.advanceCursor(to: cursor)
            }
        }

        return response
    }

    /// Sends a text prompt to the session. The message is optimistically
    /// inserted into the transcript as a local user bubble while the request is
    /// in flight.
    @discardableResult
    public func sendPrompt(sessionId: String, text: String) async throws -> String? {
        guard connectionState == .connected else {
            throw ConnectionError.notConnected
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConnectionError.rpcError(code: -32602, message: "Empty prompt")
        }

        mutateConversation(sessionId) { conv in
            conv.isSending = true
            conv.errorMessage = nil
            conv.transcript.appendLocalUserMessage(trimmed)
        }
        defer {
            mutateConversation(sessionId) { conv in
                conv.isSending = false
                conv.transcript.markIdle()
            }
        }

        let block: [String: AnyCodable] = [
            "type": AnyCodable("text"),
            "text": AnyCodable(trimmed),
        ]
        let params: [String: AnyCodable] = [
            "sessionId": AnyCodable(sessionId),
            "prompt": AnyCodable([AnyCodable(block)]),
        ]

        do {
            let result = try await rpc.request("session/prompt", params: params)
            let response = try result.decode(PromptResponse.self)
            return response.stopReason
        } catch let error as ConnectionError {
            mutateConversation(sessionId) { conv in
                conv.errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    /// Issues a `session/cancel` notification to stop the current generation.
    /// Safe to call repeatedly; a no-op when nothing is in flight.
    public func cancelSession(id sessionId: String) async throws {
        guard connectionState == .connected else {
            throw ConnectionError.notConnected
        }
        let params: [String: AnyCodable] = ["sessionId": AnyCodable(sessionId)]
        try await rpc.notify("session/cancel", params: params)
        mutateConversation(sessionId) { conv in
            conv.transcript.markIdle()
            conv.isSending = false
        }
    }

    private func mutateConversation(_ sessionId: String, _ update: (inout SessionConversation) -> Void) {
        var conv = conversations[sessionId] ?? SessionConversation()
        update(&conv)
        conversations[sessionId] = conv
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
            mutateConversation(update.sessionId) { conv in
                conv.apply(update.update, cursor: notification.cursor)
            }
        }

        // The session's `lastActiveAt` and status live on the list, so keep it
        // in step with the stream.
        Task {
            _ = try? await self.refreshSessions()
        }
    }
}
