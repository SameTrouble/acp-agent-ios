import Foundation
import Testing
@testable import ACPAgentCore

@Suite struct JsonRpcClientTests {

    @Test func authSuccessSetsAuthenticatedAndReturnsTrue() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["auth"] = { id, params in
            #expect(params?["token"]?.value.base as? String == "secret")
            return successResponse(id: id, resultJSON: #"{"ok":true}"#)
        }

        let client = JsonRpcClient(transport: transport)
        try await client.connect(url: URL(string: "ws://localhost:8787")!)
        let ok = try await client.authenticate(token: "secret")
        #expect(ok)
        #expect(transport.methodsSent().contains("auth"))
    }

    @Test func authUnauthorizedReturnsError() async {
        let transport = MockWebSocketTransport()
        transport.responders["auth"] = { id, _ in
            errorResponse(id: id, code: -32001, message: "invalid token")
        }

        let client = JsonRpcClient(transport: transport)
        try? await client.connect(url: URL(string: "ws://localhost:8787")!)
        do {
            _ = try await client.authenticate(token: "bad")
            Issue.record("Expected error")
        } catch let error as ConnectionError {
            #expect(error == .unauthorized)
        } catch {
            Issue.record("Wrong error type")
        }
    }

    @Test func requestSendsJsonRpcFrame() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session.list"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"sessions":[]}"#)
        }

        let client = JsonRpcClient(transport: transport)
        try await client.connect(url: URL(string: "ws://localhost:8787")!)
        let result = try await client.request("session.list")
        let list = try result.decode(SessionListResponse.self)
        #expect(list.sessions.isEmpty)
        #expect(transport.methodsSent() == ["session.list"])
    }

    @Test func rpcErrorIsThrown() async {
        let transport = MockWebSocketTransport()
        transport.responders["session.list"] = { id, _ in
            errorResponse(id: id, code: -32601, message: "method not found")
        }

        let client = JsonRpcClient(transport: transport)
        try? await client.connect(url: URL(string: "ws://localhost:8787")!)
        do {
            _ = try await client.request("session.list")
            Issue.record("Expected error")
        } catch let error as ConnectionError {
            if case .rpcError(let code, let message) = error {
                #expect(code == -32601)
                #expect(message == "method not found")
            } else {
                Issue.record("Expected rpcError")
            }
        } catch {
            Issue.record("Wrong error type")
        }
    }

    @Test func notificationsAreForwardedToHandler() async {
        let transport = MockWebSocketTransport()
        let client = JsonRpcClient(transport: transport)

        let received = ActorLocked(value: [String]())
        client.onNotificationHandler = { notif in
            Task { await received.append(notif.method) }
        }

        try? await client.connect(url: URL(string: "ws://localhost:8787")!)
        transport.emit(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1"},"cursor":5}"#)

        try? await Task.sleep(nanoseconds: 50_000_000)
        let values = await received.value
        #expect(values == ["session/update"])
    }

    @Test func disconnectClearsPendingRequests() async {
        let transport = MockWebSocketTransport()
        let client = JsonRpcClient(transport: transport)
        try? await client.connect(url: URL(string: "ws://localhost:8787")!)

        async let request: () = {
            do {
                _ = try await client.request("session.list")
                Issue.record("Expected error")
            } catch {
                // expected
            }
        }()

        try? await Task.sleep(nanoseconds: 10_000_000)
        await client.disconnect()
        await request
    }
}

/// Actor-backed collector, because NSLock is unavailable from async contexts.
actor ActorLocked<T> {
    var value: T
    init(value: T) { self.value = value }
}

extension ActorLocked where T == [String] {
    func append(_ element: String) { value.append(element) }
}
