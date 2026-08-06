import Foundation
import Testing
@testable import ACPAgentCore

@MainActor
@Suite struct ACPClientTests {

    @Test func connectAndAuthSucceedsAndPersistsCredentials() async throws {
        let transport = MockWebSocketTransport()
        let store = InMemoryTokenStore()
        let endpoint = ServerEndpoint(host: "localhost", port: 8787)
        let token = "abc123"

        transport.responders["auth"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"ok":true}"#)
        }

        let client = ACPClient(transport: transport, tokenStore: store)
        let ok = await client.connect(endpoint: endpoint, token: token)

        #expect(ok)
        #expect(client.connectionState == .connected)
        #expect(store.storedTokens["ws://localhost:8787"] == "abc123")
        #expect(store.loadEndpoint() == "ws://localhost:8787")
    }

    @Test func connectWithBadTokenMarksFailedAndDoesNotPersist() async {
        let transport = MockWebSocketTransport()
        let store = InMemoryTokenStore()
        let endpoint = ServerEndpoint(host: "localhost", port: 8787)

        transport.responders["auth"] = { id, _ in
            errorResponse(id: id, code: -32001, message: "invalid token")
        }

        let client = ACPClient(transport: transport, tokenStore: store)
        let ok = await client.connect(endpoint: endpoint, token: "bad")

        #expect(!ok)
        if case .failed(let message) = client.connectionState {
            #expect(message == "Invalid token")
        } else {
            Issue.record("Expected failed state, got \(client.connectionState)")
        }
        #expect(store.storedTokens.isEmpty)
    }

    @Test func connectionFailureMarksFailedState() async {
        let transport = MockWebSocketTransport()
        transport.connectError = NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "refused"])
        let store = InMemoryTokenStore()
        let endpoint = ServerEndpoint(host: "localhost", port: 8787)

        let client = ACPClient(transport: transport, tokenStore: store)
        let ok = await client.connect(endpoint: endpoint, token: "x")

        #expect(!ok)
        if case .failed(let message) = client.connectionState {
            #expect(message.contains("Connection failed"))
        } else {
            Issue.record("Expected failed state")
        }
    }

    @Test func refreshSessionsPopulatesListAndGroupsWork() async throws {
        let transport = MockWebSocketTransport()
        let store = InMemoryTokenStore()
        let endpoint = ServerEndpoint(host: "localhost", port: 8787)

        transport.responders["auth"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"ok":true}"#)
        }
        transport.responders["session.list"] = { id, _ in
            let sessionsJSON = [
                sessionJSON(id: "s1", cwd: "/proj/alpha", status: "active",
                            hasPendingApproval: true, lastActiveAt: 3000),
                sessionJSON(id: "s2", cwd: "/proj/alpha", status: "ended",
                            hasPendingApproval: false, lastActiveAt: 2000),
                sessionJSON(id: "s3", cwd: "/proj/beta", status: "interrupted",
                            hasPendingApproval: false, lastActiveAt: 1000),
            ].joined(separator: ",")
            return successResponse(id: id, resultJSON: #"{"sessions":[\#(sessionsJSON)]}"#)
        }

        let client = ACPClient(transport: transport, tokenStore: store)
        _ = await client.connect(endpoint: endpoint, token: "tok")

        let sessions = try await client.refreshSessions()
        #expect(sessions.count == 3)
        #expect(client.sessions.count == 3)

        let groups = client.sessions.groupedByProject()
        #expect(groups.count == 2)
        let alpha = groups.first { $0.cwd == "/proj/alpha" }
        #expect(alpha?.name == "alpha")
        #expect(alpha?.pendingCount == 1)
        let beta = groups.first { $0.cwd == "/proj/beta" }
        #expect(beta?.name == "beta")
        #expect(beta?.pendingCount == 0)
    }

    @Test func signOutClearsTokenAndDisconnects() async {
        let transport = MockWebSocketTransport()
        let store = InMemoryTokenStore(
            tokens: ["ws://localhost:8787": "tok"],
            endpoint: "ws://localhost:8787"
        )
        let endpoint = ServerEndpoint(host: "localhost", port: 8787)

        transport.responders["auth"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"ok":true}"#)
        }

        let client = ACPClient(transport: transport, tokenStore: store)
        _ = await client.connect(endpoint: endpoint, token: "tok")
        await client.signOut()

        #expect(client.connectionState == .disconnected)
        #expect(store.storedTokens["ws://localhost:8787"] == nil)
        #expect(store.loadEndpoint() == "")
        #expect(transport.didDisconnect)
    }

    @Test func loadPersistedCredentialsReturnsSavedPair() {
        let store = InMemoryTokenStore(
            tokens: ["ws://localhost:8787": "secret"],
            endpoint: "ws://localhost:8787"
        )
        let client = ACPClient(transport: MockWebSocketTransport(), tokenStore: store)
        let creds = client.loadPersistedCredentials()
        #expect(creds?.endpoint.host == "localhost")
        #expect(creds?.endpoint.port == 8787)
        #expect(creds?.token == "secret")
    }

    @Test func loadPersistedCredentialsReturnsNilWhenMissing() {
        let store = InMemoryTokenStore()
        let client = ACPClient(transport: MockWebSocketTransport(), tokenStore: store)
        #expect(client.loadPersistedCredentials() == nil)
    }

    @Test func refreshBeforeConnectingThrowsNotConnected() async {
        let client = ACPClient(transport: MockWebSocketTransport(), tokenStore: InMemoryTokenStore())
        do {
            _ = try await client.refreshSessions()
            Issue.record("Expected error")
        } catch let error as ConnectionError {
            #expect(error == .notConnected)
        } catch {
            Issue.record("Wrong error")
        }
    }
}
