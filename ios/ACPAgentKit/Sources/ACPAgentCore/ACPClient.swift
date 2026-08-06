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
        if notification.method == "session/update" {
            Task {
                _ = try? await self.refreshSessions()
            }
        }
    }
}
