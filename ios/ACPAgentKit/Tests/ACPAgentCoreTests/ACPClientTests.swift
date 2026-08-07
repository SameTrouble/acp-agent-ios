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

    @Test func searchFilesQueriesCompanionAndReturnsRelativePaths() async throws {
        let transport = MockWebSocketTransport()
        let store = InMemoryTokenStore()
        let endpoint = ServerEndpoint(host: "localhost", port: 8787)

        transport.responders["auth"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"ok":true}"#)
        }
        transport.responders["files.search"] = { id, _ in
            let filesJSON = [
                #"{"path":"ios/App/ACPAgent/SessionDetailView.swift","score":950}"#,
                #"{"path":"ios/App/ACPAgent/SessionListView.swift","score":900}"#,
            ].joined(separator: ",")
            return successResponse(id: id, resultJSON: #"{"files":[\#(filesJSON)]}"#)
        }

        let client = ACPClient(transport: transport, tokenStore: store)
        _ = await client.connect(endpoint: endpoint, token: "tok")

        let results = try await client.searchFiles(sessionId: "s1", query: "session")

        #expect(results.count == 2)
        #expect(results[0].path == "ios/App/ACPAgent/SessionDetailView.swift")
        #expect(results[0].score == 950)
        #expect(results[1].path == "ios/App/ACPAgent/SessionListView.swift")
        #expect(results[1].score == 900)

        let searchParams = transport.sentRequests()
            .first { $0.method == "files.search" }?.params
        #expect(searchParams?["sessionId"]?.value.base as? String == "s1")
        #expect(searchParams?["query"]?.value.base as? String == "session")
        #expect(searchParams?["limit"]?.value.base as? Int == 20)
    }

    @Test func searchFilesWhenDisconnectedThrowsNotConnected() async {
        let client = ACPClient(transport: MockWebSocketTransport(), tokenStore: InMemoryTokenStore())

        await #expect(throws: ConnectionError.notConnected) {
            try await client.searchFiles(sessionId: "s1", query: "x")
        }
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

    // MARK: - Directory browsing (issue #12)

    @Test func browseDirectoryDecodesListingAndPassesPath() async throws {
        let transport = MockWebSocketTransport()
        let endpoint = ServerEndpoint(host: "localhost", port: 8787)

        transport.responders["auth"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"ok":true}"#)
        }
        transport.responders["dir.browse"] = { id, _ in
            successResponse(
                id: id,
                resultJSON: #"{"path":"/Users/me/code","parent":"/Users/me","entries":[{"name":"acp-agent-ios","path":"/Users/me/code/acp-agent-ios"},{"name":"other","path":"/Users/me/code/other"}]}"#
            )
        }

        let client = ACPClient(transport: transport, tokenStore: InMemoryTokenStore())
        _ = await client.connect(endpoint: endpoint, token: "tok")

        let listing = try await client.browseDirectory(path: "/Users/me/code")
        #expect(listing.path == "/Users/me/code")
        #expect(listing.parent == "/Users/me")
        #expect(listing.entries.count == 2)
        #expect(listing.entries[0].name == "acp-agent-ios")
        #expect(listing.entries[0].path == "/Users/me/code/acp-agent-ios")

        let params = transport.sentRequests().first { $0.method == "dir.browse" }?.params
        #expect(params?["path"]?.value.base as? String == "/Users/me/code")
    }

    @Test func browseDirectoryWithoutPathOmitsParams() async throws {
        let transport = MockWebSocketTransport()
        let endpoint = ServerEndpoint(host: "localhost", port: 8787)

        transport.responders["auth"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"ok":true}"#)
        }
        transport.responders["dir.browse"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"path":"/Users/me","parent":"/Users","entries":[]}"#)
        }

        let client = ACPClient(transport: transport, tokenStore: InMemoryTokenStore())
        _ = await client.connect(endpoint: endpoint, token: "tok")

        let listing = try await client.browseDirectory()
        #expect(listing.path == "/Users/me")
        #expect(listing.entries.isEmpty)

        let request = transport.sentRequests().first { $0.method == "dir.browse" }
        #expect(request?.params == nil)
    }

    @Test func browseDirectoryDecodesNullParentAtRoot() throws {
        let json = #"{"path":"/","parent":null,"entries":[]}"#
        let listing = try JSONDecoder().decode(DirectoryListing.self, from: Data(json.utf8))
        #expect(listing.parent == nil)
        #expect(listing.path == "/")
    }

    @Test func browseDirectoryWhenDisconnectedThrowsNotConnected() async {
        let client = ACPClient(transport: MockWebSocketTransport(), tokenStore: InMemoryTokenStore())
        await #expect(throws: ConnectionError.notConnected) {
            _ = try await client.browseDirectory(path: "/")
        }
    }

    // MARK: - Session creation (issue #12)

    @Test func createSessionSendsCwdAndRefreshesList() async throws {
        let transport = MockWebSocketTransport()
        let endpoint = ServerEndpoint(host: "localhost", port: 8787)

        transport.responders["auth"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"ok":true}"#)
        }
        transport.responders["session/new"] = { id, params in
            let cwd = params?["cwd"]?.value.base as? String ?? ""
            return successResponse(id: id, resultJSON: #"{"sessionId":"sess_new","cwd":"\#(cwd)"}"#)
        }
        transport.responders["session.list"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"sessions":[\#(sessionJSON(id: "sess_new", cwd: "/proj/new"))]}"#)
        }

        let client = ACPClient(transport: transport, tokenStore: InMemoryTokenStore())
        _ = await client.connect(endpoint: endpoint, token: "tok")

        let sessionId = try await client.createSession(cwd: "/proj/new")
        #expect(sessionId == "sess_new")

        let params = transport.sentRequests().first { $0.method == "session/new" }?.params
        #expect(params?["cwd"]?.value.base as? String == "/proj/new")

        // The session list is refreshed so the new session is visible at once.
        #expect(transport.methodsSent().contains("session.list"))
        #expect(client.sessions.first?.id == "sess_new")
    }

    @Test func createSessionWhenDisconnectedThrowsNotConnected() async {
        let client = ACPClient(transport: MockWebSocketTransport(), tokenStore: InMemoryTokenStore())
        await #expect(throws: ConnectionError.notConnected) {
            _ = try await client.createSession(cwd: "/proj/x")
        }
    }
}
