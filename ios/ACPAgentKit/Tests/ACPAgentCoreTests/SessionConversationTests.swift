import Combine
import Foundation
import Testing
@testable import ACPAgentCore

@MainActor
@Suite struct SessionConversationTests {

    /// Connects a client whose transport answers `auth` and `session.list`.
    private func connectedClient(
        _ transport: MockWebSocketTransport
    ) async -> ACPClient {
        transport.responders["auth"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"ok":true}"#)
        }
        if transport.responders["session.list"] == nil {
            transport.responders["session.list"] = { id, _ in
                successResponse(id: id, resultJSON: #"{"sessions":[]}"#)
            }
        }
        let client = ACPClient(transport: transport, tokenStore: InMemoryTokenStore())
        _ = await client.connect(endpoint: ServerEndpoint(host: "localhost", port: 8787), token: "tok")
        return client
    }

    /// Notifications hop through a dispatch queue and a `Task { @MainActor }`,
    /// so yield until the expectation holds or we run out of patience.
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        attempts: Int = 200
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    // MARK: - resume

    @Test func resumeReplaysBufferedEventsIntoTranscript() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session.resume"] = { id, _ in
            let events = [
                #"{"method":"session/update","params":{"sessionId":"s1","update":\#(agentChunkJSON("Hello "))},"cursor":1}"#,
                #"{"method":"session/update","params":{"sessionId":"s1","update":\#(agentChunkJSON("world"))},"cursor":2}"#,
            ].joined(separator: ",")
            return successResponse(id: id, resultJSON: #"{"sessionId":"s1","recovery":"replay","events":[\#(events)],"cursor":2}"#)
        }
        let client = await connectedClient(transport)

        try await client.resumeSession(id: "s1")

        let conversation = client.conversation(for: "s1")
        #expect(conversation.recovery == .replay)
        #expect(conversation.cursor == 2)
        #expect(conversation.transcript.messages.count == 1)
        #expect(conversation.transcript.messages[0].text == "Hello world")
    }

    @Test func resumeSendsLastKnownCursorOnReconnect() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session.resume"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"sessionId":"s1","recovery":"replay","events":[],"cursor":7}"#)
        }
        let client = await connectedClient(transport)

        try await client.resumeSession(id: "s1")
        #expect(client.conversation(for: "s1").cursor == 7)

        try await client.resumeSession(id: "s1")

        let resumeParams = transport.sentRequests()
            .filter { $0.method == "session.resume" }
            .compactMap { $0.params }
        #expect(resumeParams.count == 2)
        #expect(resumeParams[0]["cursor"] == nil)
        #expect(resumeParams[1]["cursor"]?.value.base as? Int == 7)
    }

    @Test func liveOnlyRecoveryIsSurfacedWithReason() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session.resume"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"sessionId":"s1","recovery":"live-only","events":[],"cursor":42,"reason":"agent cannot replay session history"}"#)
        }
        let client = await connectedClient(transport)

        try await client.resumeSession(id: "s1")

        let conversation = client.conversation(for: "s1")
        #expect(conversation.recovery == .liveOnly)
        #expect(conversation.recoveryReason == "agent cannot replay session history")
        #expect(conversation.cursor == 42)
    }

    @Test func snapshotRecoveryKeepsCursorWithoutEvents() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session.resume"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"sessionId":"s1","recovery":"snapshot","mcpServers":[],"cursor":13}"#)
        }
        let client = await connectedClient(transport)

        try await client.resumeSession(id: "s1")

        #expect(client.conversation(for: "s1").recovery == .snapshot)
        #expect(client.conversation(for: "s1").cursor == 13)
    }

    @Test func resumeBeforeConnectingThrowsNotConnected() async {
        let client = ACPClient(transport: MockWebSocketTransport(), tokenStore: InMemoryTokenStore())
        await #expect(throws: ConnectionError.notConnected) {
            try await client.resumeSession(id: "s1")
        }
    }

    // MARK: - live notifications

    @Test func liveUpdatesAccumulateAndAdvanceCursor() async throws {
        let transport = MockWebSocketTransport()
        let client = await connectedClient(transport)

        transport.emit(sessionUpdateNotificationJSON(sessionId: "s1", updateJSON: agentChunkJSON("Hi "), cursor: 4))
        transport.emit(sessionUpdateNotificationJSON(sessionId: "s1", updateJSON: agentChunkJSON("there"), cursor: 5))

        let arrived = await waitUntil { client.conversation(for: "s1").cursor == 5 }
        #expect(arrived)
        #expect(client.conversation(for: "s1").transcript.messages.first?.text == "Hi there")
    }

    @Test func updatesAreRoutedToTheirOwnSession() async throws {
        let transport = MockWebSocketTransport()
        let client = await connectedClient(transport)

        transport.emit(sessionUpdateNotificationJSON(sessionId: "s1", updateJSON: agentChunkJSON("for one"), cursor: 1))
        transport.emit(sessionUpdateNotificationJSON(sessionId: "s2", updateJSON: agentChunkJSON("for two"), cursor: 1))

        let arrived = await waitUntil {
            !client.conversation(for: "s1").transcript.messages.isEmpty &&
            !client.conversation(for: "s2").transcript.messages.isEmpty
        }
        #expect(arrived)
        #expect(client.conversation(for: "s1").transcript.messages[0].text == "for one")
        #expect(client.conversation(for: "s2").transcript.messages[0].text == "for two")
    }

    @Test func toolCallUpdatesMergeIntoOneCard() async throws {
        let transport = MockWebSocketTransport()
        let client = await connectedClient(transport)

        transport.emit(sessionUpdateNotificationJSON(
            sessionId: "s1",
            updateJSON: toolCallJSON(id: "t1", title: "Read main.swift", kind: "read", status: "pending"),
            cursor: 1
        ))
        transport.emit(sessionUpdateNotificationJSON(
            sessionId: "s1",
            updateJSON: toolCallUpdateJSON(id: "t1", status: "completed"),
            cursor: 2
        ))

        let arrived = await waitUntil {
            client.conversation(for: "s1").transcript.toolCalls.first?.status == .completed
        }
        #expect(arrived)
        let toolCalls = client.conversation(for: "s1").transcript.toolCalls
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0].title == "Read main.swift")
    }

    @Test func staleCursorEventIsDiscardedNotReapplied() async throws {
        let transport = MockWebSocketTransport()
        let client = await connectedClient(transport)

        transport.emit(sessionUpdateNotificationJSON(sessionId: "s1", updateJSON: agentChunkJSON("a"), cursor: 10))
        _ = await waitUntil { client.conversation(for: "s1").cursor == 10 }

        // A replayed / out-of-order frame we have already seen must not be
        // applied again, or the transcript would duplicate content.
        transport.emit(sessionUpdateNotificationJSON(sessionId: "s1", updateJSON: agentChunkJSON("b"), cursor: 3))
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(client.conversation(for: "s1").cursor == 10)
        #expect(client.conversation(for: "s1").transcript.messages.first?.text == "a")
    }

    @Test func newerCursorEventIsApplied() async throws {
        let transport = MockWebSocketTransport()
        let client = await connectedClient(transport)

        transport.emit(sessionUpdateNotificationJSON(sessionId: "s1", updateJSON: agentChunkJSON("a"), cursor: 10))
        _ = await waitUntil { client.conversation(for: "s1").cursor == 10 }

        transport.emit(sessionUpdateNotificationJSON(sessionId: "s1", updateJSON: agentChunkJSON("b"), cursor: 11))
        let arrived = await waitUntil { client.conversation(for: "s1").cursor == 11 }

        #expect(arrived)
        #expect(client.conversation(for: "s1").transcript.messages.first?.text == "ab")
    }

    // MARK: - prompt

    @Test func sendPromptEchoesUserTextAndSendsTextBlock() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session/prompt"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"stopReason":"end_turn"}"#)
        }
        let client = await connectedClient(transport)

        let stopReason = try await client.sendPrompt(sessionId: "s1", text: "explain this")

        #expect(stopReason == "end_turn")
        let conversation = client.conversation(for: "s1")
        #expect(conversation.transcript.messages.count == 1)
        #expect(conversation.transcript.messages[0].role == .user)
        #expect(conversation.transcript.messages[0].text == "explain this")
        #expect(!conversation.isSending)

        let promptRequest = transport.sentRequests().first { $0.method == "session/prompt" }
        #expect(promptRequest?.params?["sessionId"]?.value.base as? String == "s1")
        let blocks = promptRequest?.params?["prompt"]?.value.base as? [AnyCodable]
        #expect(blocks?.count == 1)
        let block = blocks?[0].value.base as? [String: AnyCodable]
        #expect(block?["type"]?.value.base as? String == "text")
        #expect(block?["text"]?.value.base as? String == "explain this")
    }

    @Test func isSendingIsTrueWhileThePromptIsInFlight() async throws {
        let transport = MockWebSocketTransport()
        transport.deferredMethods = ["session/prompt"]
        let client = await connectedClient(transport)

        let promptTask = Task { try await client.sendPrompt(sessionId: "s1", text: "go") }
        let started = await waitUntil { client.conversation(for: "s1").isSending }
        #expect(started)

        transport.release("session/prompt", resultJSON: #"{"stopReason":"end_turn"}"#)
        _ = try await promptTask.value

        #expect(!client.conversation(for: "s1").isSending)
    }

    @Test func emptyPromptIsRejectedWithoutTouchingTheWire() async {
        let transport = MockWebSocketTransport()
        let client = await connectedClient(transport)

        await #expect(throws: ConnectionError.self) {
            try await client.sendPrompt(sessionId: "s1", text: "   ")
        }
        #expect(!transport.methodsSent().contains("session/prompt"))
        #expect(client.conversation(for: "s1").transcript.messages.isEmpty)
    }

    @Test func failedPromptClearsSendingAndRecordsError() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session/prompt"] = { id, _ in
            errorResponse(id: id, code: -32603, message: "agent exploded")
        }
        let client = await connectedClient(transport)

        let thrownError: Error?
        do {
            _ = try await client.sendPrompt(sessionId: "s1", text: "go")
            thrownError = nil
        } catch {
            thrownError = error
        }
        #expect(thrownError != nil)

        let conversation = client.conversation(for: "s1")
        #expect(!conversation.isSending)
        #expect(!conversation.transcript.isGenerating)
        #expect(conversation.errorMessage != nil)
    }

    @Test func promptCompletionStopsTheGeneratingSpinner() async throws {
        let transport = MockWebSocketTransport()
        transport.deferredMethods = ["session/prompt"]
        let client = await connectedClient(transport)

        let promptTask = Task { try await client.sendPrompt(sessionId: "s1", text: "go") }
        _ = await waitUntil { client.conversation(for: "s1").isSending }

        transport.emit(sessionUpdateNotificationJSON(sessionId: "s1", updateJSON: agentChunkJSON("working"), cursor: 1))
        _ = await waitUntil { client.conversation(for: "s1").transcript.isGenerating }

        transport.release("session/prompt", resultJSON: #"{"stopReason":"end_turn"}"#)
        _ = try await promptTask.value

        #expect(!client.conversation(for: "s1").transcript.isGenerating)
    }

    // MARK: - cancel

    @Test func cancelSendsNotificationNotRequest() async throws {
        let transport = MockWebSocketTransport()
        let client = await connectedClient(transport)

        try await client.cancelSession(id: "s1")

        #expect(!transport.methodsSent().contains("session/cancel"))
        let cancels = transport.sentNotifications().filter { $0.method == "session/cancel" }
        #expect(cancels.count == 1)
        #expect(cancels[0].params?["sessionId"]?.value.base as? String == "s1")
    }

    @Test func cancelStopsTheInFlightPromptAndSpinner() async throws {
        let transport = MockWebSocketTransport()
        transport.deferredMethods = ["session/prompt"]
        let client = await connectedClient(transport)

        let promptTask = Task { try? await client.sendPrompt(sessionId: "s1", text: "long job") }
        _ = await waitUntil { client.conversation(for: "s1").isSending }

        try await client.cancelSession(id: "s1")

        transport.release("session/prompt", resultJSON: #"{"stopReason":"cancelled"}"#)
        _ = await promptTask.value

        let conversation = client.conversation(for: "s1")
        #expect(!conversation.isSending)
        #expect(!conversation.transcript.isGenerating)
    }

    @Test func cancelBeforeConnectingThrowsNotConnected() async {
        let client = ACPClient(transport: MockWebSocketTransport(), tokenStore: InMemoryTokenStore())
        await #expect(throws: ConnectionError.notConnected) {
            try await client.cancelSession(id: "s1")
        }
    }

    // MARK: - permission requests

    @Test func permissionRequestAppearsAsApprovalCardInConversation() async throws {
        let transport = MockWebSocketTransport()
        let client = await connectedClient(transport)

        transport.emit(permissionRequestJSON(sessionId: "s1", requestId: 0))

        let arrived = await waitUntil {
            !client.conversation(for: "s1").transcript.approvalCards.isEmpty
        }
        #expect(arrived)
        let card = client.conversation(for: "s1").transcript.approvalCards.first
        #expect(card?.requestId == .number(0))
        #expect(card?.state == .pending)
        #expect(card?.toolCall.title == "curl -s http://example.com")
        #expect(card?.options.count == 3)
    }

    @Test func permissionRequestIsDeduplicatedWhenRebroadcast() async throws {
        let transport = MockWebSocketTransport()
        let client = await connectedClient(transport)

        transport.emit(permissionRequestJSON(sessionId: "s1", requestId: 2))
        _ = await waitUntil {
            !client.conversation(for: "s1").transcript.approvalCards.isEmpty
        }
        transport.emit(permissionRequestJSON(sessionId: "s1", requestId: 2))
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(client.conversation(for: "s1").transcript.approvalCards.count == 1)
    }

    @Test func unknownAgentRequestMethodIsIgnored() async throws {
        let transport = MockWebSocketTransport()
        let client = await connectedClient(transport)

        transport.emit(#"{"jsonrpc":"2.0","id":9,"method":"session/something_else","params":{}}"#)
        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(client.conversation(for: "s1").transcript.items.isEmpty)
    }

    @Test func resumeReplaysBufferedPermissionRequest() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session.resume"] = { id, _ in
            let events = [
                #"{"method":"session/request_permission","params":\#(permissionRequestParamsJSON(sessionId: "s1")),"id":7,"cursor":1}"#,
                #"{"method":"session/update","params":{"sessionId":"s1","update":\#(agentChunkJSON("done"))},"cursor":2}"#,
            ].joined(separator: ",")
            return successResponse(id: id, resultJSON: #"{"sessionId":"s1","recovery":"replay","events":[\#(events)],"cursor":2}"#)
        }
        let client = await connectedClient(transport)

        try await client.resumeSession(id: "s1")

        let conversation = client.conversation(for: "s1")
        #expect(conversation.cursor == 2)
        let card = conversation.transcript.approvalCards.first
        #expect(card?.requestId == .number(7))
        #expect(card?.state == .pending)
        #expect(conversation.transcript.messages.first?.text == "done")
    }

    @Test func respondingThroughTheClientTurnsTheCardTerminal() async throws {
        let transport = MockWebSocketTransport()
        let client = await connectedClient(transport)

        transport.emit(permissionRequestJSON(sessionId: "s1", requestId: 3))
        _ = await waitUntil {
            !client.conversation(for: "s1").transcript.approvalCards.isEmpty
        }

        try await client.respondToPermission(
            sessionId: "s1",
            requestId: .number(3),
            option: PermissionOption(optionId: "once", kind: .allowOnce, name: "Allow once")
        )

        #expect(client.conversation(for: "s1").transcript.approvalCards.first?.state == .approved(optionId: "once"))
        let response = transport.sentResponses().first
        #expect(response?.id == .number(3))
        let outcome = response?.result?.value.base as? [String: AnyCodable]
        let inner = outcome?["outcome"]?.value.base as? [String: AnyCodable]
        #expect(inner?["outcome"]?.value.base as? String == "selected")
    }

    // MARK: - conversation change forwarding

    /// Views observe conversation state only through the `ACPClient`
    /// environment object, so a store change must be forwarded to the client's
    /// `objectWillChange` or the screen would silently stop re-rendering.
    @Test func storeChangesAreForwardedThroughTheClientForViews() async {
        let transport = MockWebSocketTransport()
        let client = await connectedClient(transport)

        var clientDidChange = false
        let cancellable = client.objectWillChange.sink { clientDidChange = true }
        defer { cancellable.cancel() }

        transport.emit(sessionUpdateNotificationJSON(sessionId: "s1", updateJSON: agentChunkJSON("hi"), cursor: 1))
        let arrived = await waitUntil { client.conversation(for: "s1").cursor == 1 }

        #expect(arrived)
        #expect(clientDidChange)
    }

    // MARK: - disconnect

    @Test func disconnectKeepsTranscriptsSoResumeCanContinue() async throws {
        let transport = MockWebSocketTransport()
        let client = await connectedClient(transport)

        transport.emit(sessionUpdateNotificationJSON(sessionId: "s1", updateJSON: agentChunkJSON("kept"), cursor: 9))
        _ = await waitUntil { client.conversation(for: "s1").cursor == 9 }

        await client.disconnect()

        #expect(client.conversation(for: "s1").cursor == 9)
        #expect(client.conversation(for: "s1").transcript.messages.first?.text == "kept")
    }

    @Test func signOutDiscardsTranscripts() async throws {
        let transport = MockWebSocketTransport()
        let client = await connectedClient(transport)

        transport.emit(sessionUpdateNotificationJSON(sessionId: "s1", updateJSON: agentChunkJSON("secret"), cursor: 1))
        _ = await waitUntil { !client.conversation(for: "s1").transcript.messages.isEmpty }

        await client.signOut()

        #expect(client.conversation(for: "s1").transcript.messages.isEmpty)
        #expect(client.conversation(for: "s1").cursor == nil)
    }
}
