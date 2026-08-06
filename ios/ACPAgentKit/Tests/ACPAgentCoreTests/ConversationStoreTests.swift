import Foundation
import Testing
@testable import ACPAgentCore

@MainActor
@Suite struct ConversationStoreTests {

    private func makeStore(
        _ transport: MockWebSocketTransport,
        isConnected: Bool = true
    ) -> ConversationStore {
        ConversationStore(
            rpc: JsonRpcClient(transport: transport),
            isConnected: { isConnected }
        )
    }

    // MARK: - conversation(for:)

    @Test func conversationVendsEmptyStateBeforeAnyActivity() {
        let store = makeStore(MockWebSocketTransport())

        let conversation = store.conversation(for: "s1")

        #expect(conversation.transcript.items.isEmpty)
        #expect(conversation.cursor == nil)
        #expect(!conversation.isSending)
        #expect(!conversation.isResuming)
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
        let store = makeStore(transport)

        try await store.resumeSession(id: "s1")

        let conversation = store.conversation(for: "s1")
        #expect(conversation.recovery == .replay)
        #expect(conversation.cursor == 2)
        #expect(conversation.transcript.messages.count == 1)
        #expect(conversation.transcript.messages[0].text == "Hello world")
    }

    @Test func resumeSendsLastKnownCursorOnSecondResume() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session.resume"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"sessionId":"s1","recovery":"replay","events":[],"cursor":7}"#)
        }
        let store = makeStore(transport)

        try await store.resumeSession(id: "s1")
        try await store.resumeSession(id: "s1")

        let resumeParams = transport.sentRequests()
            .filter { $0.method == "session.resume" }
            .compactMap { $0.params }
        #expect(resumeParams.count == 2)
        #expect(resumeParams[0]["cursor"] == nil)
        #expect(resumeParams[1]["cursor"]?.value.base as? Int == 7)
    }

    @Test func resumeWhenDisconnectedThrowsNotConnected() async {
        let store = makeStore(MockWebSocketTransport(), isConnected: false)

        await #expect(throws: ConnectionError.notConnected) {
            try await store.resumeSession(id: "s1")
        }
    }

    // MARK: - send

    @Test func sendPromptInsertsOptimisticUserBubbleAndSendsTextBlock() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session/prompt"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"stopReason":"end_turn"}"#)
        }
        let store = makeStore(transport)

        let stopReason = try await store.sendPrompt(sessionId: "s1", text: "explain this")

        #expect(stopReason == "end_turn")
        let conversation = store.conversation(for: "s1")
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

    @Test func sendPromptWhenDisconnectedThrowsNotConnected() async {
        let store = makeStore(MockWebSocketTransport(), isConnected: false)

        await #expect(throws: ConnectionError.notConnected) {
            try await store.sendPrompt(sessionId: "s1", text: "hi")
        }
    }

    // MARK: - cancel

    @Test func cancelSendsNotificationNotRequest() async throws {
        let transport = MockWebSocketTransport()
        let store = makeStore(transport)

        try await store.cancelSession(id: "s1")

        #expect(!transport.methodsSent().contains("session/cancel"))
        let cancels = transport.sentNotifications().filter { $0.method == "session/cancel" }
        #expect(cancels.count == 1)
        #expect(cancels[0].params?["sessionId"]?.value.base as? String == "s1")
    }

    // MARK: - session update intake

    @Test func applySessionUpdateAccumulatesAndAdvancesCursor() {
        let store = makeStore(MockWebSocketTransport())

        store.applySessionUpdate(
            SessionUpdateNotification(sessionId: "s1", update: .agentMessageChunk(.text("Hi "))),
            cursor: 4
        )
        store.applySessionUpdate(
            SessionUpdateNotification(sessionId: "s1", update: .agentMessageChunk(.text("there"))),
            cursor: 5
        )

        let conversation = store.conversation(for: "s1")
        #expect(conversation.cursor == 5)
        #expect(conversation.transcript.messages.first?.text == "Hi there")
    }

    @Test func applySessionUpdateDiscardsStaleCursor() {
        let store = makeStore(MockWebSocketTransport())

        store.applySessionUpdate(
            SessionUpdateNotification(sessionId: "s1", update: .agentMessageChunk(.text("a"))),
            cursor: 10
        )
        store.applySessionUpdate(
            SessionUpdateNotification(sessionId: "s1", update: .agentMessageChunk(.text("b"))),
            cursor: 3
        )

        let conversation = store.conversation(for: "s1")
        #expect(conversation.cursor == 10)
        #expect(conversation.transcript.messages.first?.text == "a")
    }

    // MARK: - teardown

    @Test func clearAllDropsConversations() {
        let store = makeStore(MockWebSocketTransport())
        store.applySessionUpdate(
            SessionUpdateNotification(sessionId: "s1", update: .agentMessageChunk(.text("secret"))),
            cursor: 1
        )

        store.clearAll()

        #expect(store.conversation(for: "s1").transcript.messages.isEmpty)
        #expect(store.conversation(for: "s1").cursor == nil)
    }
}
