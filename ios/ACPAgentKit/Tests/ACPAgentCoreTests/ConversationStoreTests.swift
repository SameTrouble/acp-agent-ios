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

    @Test func sendStructuredPromptSendsFileRefBlocksAndShowsClipBubble() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session/prompt"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"stopReason":"end_turn"}"#)
        }
        let store = makeStore(transport)

        let prompt: [PromptBlock] = [
            .text("what does this file do?"),
            .fileRef(path: "ios/App/ACPAgent/SessionDetailView.swift"),
        ]
        let stopReason = try await store.sendPrompt(sessionId: "s1", prompt: prompt)

        #expect(stopReason == "end_turn")
        let conversation = store.conversation(for: "s1")
        #expect(conversation.transcript.messages.count == 1)
        // The optimistic bubble shows the text plus one 📎 line per reference.
        #expect(conversation.transcript.messages[0].text.contains("what does this file do?"))
        #expect(conversation.transcript.messages[0].text.contains("📎 ios/App/ACPAgent/SessionDetailView.swift"))

        let promptRequest = transport.sentRequests().first { $0.method == "session/prompt" }
        let blocks = promptRequest?.params?["prompt"]?.value.base as? [AnyCodable]
        #expect(blocks?.count == 2)
        let textBlock = blocks?[0].value.base as? [String: AnyCodable]
        #expect(textBlock?["type"]?.value.base as? String == "text")
        #expect(textBlock?["text"]?.value.base as? String == "what does this file do?")
        let refBlock = blocks?[1].value.base as? [String: AnyCodable]
        #expect(refBlock?["type"]?.value.base as? String == "file_ref")
        #expect(refBlock?["path"]?.value.base as? String == "ios/App/ACPAgent/SessionDetailView.swift")
    }

    @Test func sendStructuredPromptDropsBlankTextButKeepsReferences() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session/prompt"] = { id, _ in
            successResponse(id: id, resultJSON: #"{"stopReason":"end_turn"}"#)
        }
        let store = makeStore(transport)

        _ = try await store.sendPrompt(sessionId: "s1", prompt: [
            .text("   "),
            .fileRef(path: "README.md"),
        ])

        let promptRequest = transport.sentRequests().first { $0.method == "session/prompt" }
        let blocks = promptRequest?.params?["prompt"]?.value.base as? [AnyCodable]
        #expect(blocks?.count == 1)
        let refBlock = blocks?[0].value.base as? [String: AnyCodable]
        #expect(refBlock?["type"]?.value.base as? String == "file_ref")
        #expect(refBlock?["path"]?.value.base as? String == "README.md")
    }

    @Test func sendAllBlankStructuredPromptThrows() async {
        let store = makeStore(MockWebSocketTransport())

        await #expect(throws: ConnectionError.rpcError(code: -32602, message: "Empty prompt")) {
            try await store.sendPrompt(sessionId: "s1", prompt: [.text("  \n ")])
        }
        #expect(store.conversation(for: "s1").transcript.items.isEmpty)
    }

    @Test func applyAvailableCommandsUpdateReplacesDirectoryOutsideTranscript() {
        let store = makeStore(MockWebSocketTransport())

        store.applySessionUpdate(
            SessionUpdateNotification(
                sessionId: "s1",
                update: .availableCommands([AvailableCommand(name: "tdd", description: "TDD")])
            ),
            cursor: 1
        )
        store.applySessionUpdate(
            SessionUpdateNotification(
                sessionId: "s1",
                update: .availableCommands([AvailableCommand(name: "init"), AvailableCommand(name: "review")])
            ),
            cursor: 2
        )

        let conversation = store.conversation(for: "s1")
        // The directory is replaced wholesale, not appended.
        #expect(conversation.availableCommands == [
            AvailableCommand(name: "init"),
            AvailableCommand(name: "review"),
        ])
        // Command directory is session state, not transcript content.
        #expect(conversation.transcript.items.isEmpty)
        // It still participates in cursor tracking.
        #expect(conversation.cursor == 2)
    }

    @Test func applyConfigOptionUpdateReplacesOptionsOutsideTranscript() {
        let store = makeStore(MockWebSocketTransport())

        store.applySessionUpdate(
            SessionUpdateNotification(
                sessionId: "s1",
                update: .configOptions([
                    SessionConfigOption(
                        id: "model", name: "Model", category: "model", type: .select,
                        currentValue: .string("m1"),
                        options: [SessionConfigOptionValue(value: "m1", name: "M1")]
                    ),
                ])
            ),
            cursor: 1
        )
        store.applySessionUpdate(
            SessionUpdateNotification(
                sessionId: "s1",
                update: .configOptions([
                    SessionConfigOption(
                        id: "model", name: "Model", category: "model", type: .select,
                        currentValue: .string("m2"),
                        options: [
                            SessionConfigOptionValue(value: "m1", name: "M1"),
                            SessionConfigOptionValue(value: "m2", name: "M2"),
                        ]
                    ),
                ])
            ),
            cursor: 2
        )

        let conversation = store.conversation(for: "s1")
        #expect(conversation.configChipSummary == "M2")
        #expect(conversation.transcript.items.isEmpty)
        #expect(conversation.cursor == 2)
    }

    @Test func resumeSeedsConfigOptionsFromResponse() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session.resume"] = { id, _ in
            successResponse(id: id, resultJSON: #"""
            {"sessionId":"s1","recovery":"replay","events":[],"cursor":0,"configOptions":[
              {"id":"model","name":"Model","category":"model","type":"select","currentValue":"m1","options":[{"value":"m1","name":"Claude"}]}
            ]}
            """#)
        }
        let store = makeStore(transport)

        try await store.resumeSession(id: "s1")

        #expect(store.conversation(for: "s1").configChipSummary == "Claude")
    }

    @Test func setConfigOptionReplacesLocalStateFromAgentResponse() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session/set_config_option"] = { id, params in
            #expect(params?["configId"]?.value.base as? String == "model")
            #expect(params?["value"]?.value.base as? String == "m2")
            return successResponse(id: id, resultJSON: #"""
            {"configOptions":[
              {"id":"model","name":"Model","category":"model","type":"select","currentValue":"m2","options":[
                {"value":"m1","name":"M1"},{"value":"m2","name":"M2"}
              ]}
            ]}
            """#)
        }
        let store = makeStore(transport)
        store.applySessionUpdate(
            SessionUpdateNotification(
                sessionId: "s1",
                update: .configOptions([
                    SessionConfigOption(
                        id: "model", name: "Model", category: "model", type: .select,
                        currentValue: .string("m1"),
                        options: [SessionConfigOptionValue(value: "m1", name: "M1")]
                    ),
                ])
            ),
            cursor: 1
        )

        let options = try await store.setConfigOption(sessionId: "s1", configId: "model", value: "m2")

        #expect(options.first?.currentDisplayName == "M2")
        #expect(store.conversation(for: "s1").configChipSummary == "M2")
        #expect(transport.methodsSent() == ["session/set_config_option"])
    }

    @Test func setConfigOptionFallsBackToSetModeWhenOnlyModesExist() async throws {
        let transport = MockWebSocketTransport()
        transport.responders["session.resume"] = { id, _ in
            successResponse(id: id, resultJSON: #"""
            {"sessionId":"s1","recovery":"replay","events":[],"modes":{
              "currentModeId":"ask",
              "availableModes":[{"id":"ask","name":"Ask"},{"id":"code","name":"Code"}]
            }}
            """#)
        }
        transport.responders["session/set_mode"] = { id, params in
            #expect(params?["modeId"]?.value.base as? String == "code")
            return successResponse(id: id, resultJSON: "{}")
        }
        let store = makeStore(transport)
        try await store.resumeSession(id: "s1")

        _ = try await store.setConfigOption(sessionId: "s1", configId: "mode", value: "code")

        #expect(store.conversation(for: "s1").configChipSummary == "Code")
        #expect(transport.methodsSent().contains("session/set_mode"))
        #expect(!transport.methodsSent().contains("session/set_config_option"))
    }

    @Test func setConfigOptionAllowedWhileSending() async throws {
        let transport = MockWebSocketTransport()
        transport.deferredMethods = ["session/prompt"]
        transport.responders["session/set_config_option"] = { id, _ in
            successResponse(id: id, resultJSON: #"""
            {"configOptions":[
              {"id":"model","name":"Model","category":"model","type":"select","currentValue":"m2","options":[
                {"value":"m1","name":"M1"},{"value":"m2","name":"M2"}
              ]}
            ]}
            """#)
        }
        let store = makeStore(transport)
        store.applySessionUpdate(
            SessionUpdateNotification(
                sessionId: "s1",
                update: .configOptions([
                    SessionConfigOption(
                        id: "model", name: "Model", category: "model", type: .select,
                        currentValue: .string("m1"),
                        options: [SessionConfigOptionValue(value: "m1", name: "M1")]
                    ),
                ])
            ),
            cursor: 1
        )

        async let prompt: String? = store.sendPrompt(sessionId: "s1", text: "hi")
        // Let the prompt start so isSending flips true.
        await Task.yield()
        #expect(store.conversation(for: "s1").isSending)

        _ = try await store.setConfigOption(sessionId: "s1", configId: "model", value: "m2")
        #expect(store.conversation(for: "s1").configChipSummary == "M2")

        transport.release("session/prompt", resultJSON: #"{"stopReason":"end_turn"}"#)
        _ = try await prompt
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

    // MARK: - permissions

    private func makePermissionRequest(requestId: JsonRpcId) -> PermissionRequest {
        var request = PermissionRequest(
            sessionId: "s1",
            toolCall: PermissionToolCall(
                toolCallId: "call_1",
                title: "curl -s http://example.com",
                kind: "execute",
                locations: ["/etc/hosts"],
                rawInput: ["command": AnyCodable("curl -s http://example.com")]
            ),
            options: [
                PermissionOption(optionId: "once", kind: .allowOnce, name: "Allow once"),
                PermissionOption(optionId: "always", kind: .allowAlways, name: "Always allow"),
                PermissionOption(optionId: "reject", kind: .rejectOnce, name: "Reject"),
            ]
        )
        request.requestId = requestId
        return request
    }

    @Test func applyPermissionRequestAddsPendingCard() {
        let store = makeStore(MockWebSocketTransport())

        store.applyPermissionRequest(makePermissionRequest(requestId: .number(0)))

        let card = store.conversation(for: "s1").transcript.approvalCards.first
        #expect(card?.state == .pending)
        #expect(card?.requestId == .number(0))
        #expect(card?.toolCall.title == "curl -s http://example.com")
        #expect(card?.options.count == 3)
    }

    @Test func respondToPermissionSendsADR005ResultAndTurnsCardTerminal() async throws {
        let transport = MockWebSocketTransport()
        let store = makeStore(transport)
        store.applyPermissionRequest(makePermissionRequest(requestId: .number(0)))

        try await store.respondToPermission(
            sessionId: "s1",
            requestId: .number(0),
            option: PermissionOption(optionId: "once", kind: .allowOnce, name: "Allow once")
        )

        let responses = transport.sentResponses()
        #expect(responses.count == 1)
        #expect(responses[0].id == .number(0))
        let outcome = responses[0].result?.value.base as? [String: AnyCodable]
        let inner = outcome?["outcome"]?.value.base as? [String: AnyCodable]
        #expect(inner?["outcome"]?.value.base as? String == "selected")
        #expect(inner?["optionId"]?.value.base as? String == "once")

        let card = store.conversation(for: "s1").transcript.approvalCards.first
        #expect(card?.state == .approved(optionId: "once"))
    }

    @Test func rejectPermissionSendsRejectedOutcome() async throws {
        let transport = MockWebSocketTransport()
        let store = makeStore(transport)
        store.applyPermissionRequest(makePermissionRequest(requestId: .number(5)))

        try await store.respondToPermission(
            sessionId: "s1",
            requestId: .number(5),
            option: PermissionOption(optionId: "reject", kind: .rejectOnce, name: "Reject")
        )

        let responses = transport.sentResponses()
        #expect(responses.count == 1)
        #expect(responses[0].id == .number(5))
        let outcome = responses[0].result?.value.base as? [String: AnyCodable]
        let inner = outcome?["outcome"]?.value.base as? [String: AnyCodable]
        #expect(inner?["outcome"]?.value.base as? String == "rejected")
        #expect(inner?["optionId"] == nil)

        #expect(store.conversation(for: "s1").transcript.approvalCards.first?.state == .rejected)
    }

    @Test func secondResponseToSameRequestIsASilentNoOp() async throws {
        let transport = MockWebSocketTransport()
        let store = makeStore(transport)
        store.applyPermissionRequest(makePermissionRequest(requestId: .number(1)))

        try await store.respondToPermission(
            sessionId: "s1",
            requestId: .number(1),
            option: PermissionOption(optionId: "once", kind: .allowOnce, name: "Allow once")
        )
        try await store.respondToPermission(
            sessionId: "s1",
            requestId: .number(1),
            option: PermissionOption(optionId: "always", kind: .allowAlways, name: "Always allow")
        )

        // One receipt only; the card keeps the first choice.
        #expect(transport.sentResponses().count == 1)
        #expect(store.conversation(for: "s1").transcript.approvalCards.first?.state == .approved(optionId: "once"))
    }

    @Test func respondToUnknownRequestSendsNothing() async throws {
        let transport = MockWebSocketTransport()
        let store = makeStore(transport)

        try await store.respondToPermission(
            sessionId: "s1",
            requestId: .number(42),
            option: PermissionOption(optionId: "once", kind: .allowOnce, name: "Allow once")
        )

        #expect(transport.sentResponses().isEmpty)
    }

    @Test func respondToPermissionWhenDisconnectedThrows() async {
        let store = makeStore(MockWebSocketTransport(), isConnected: false)
        store.applyPermissionRequest(makePermissionRequest(requestId: .number(0)))

        await #expect(throws: ConnectionError.notConnected) {
            try await store.respondToPermission(
                sessionId: "s1",
                requestId: .number(0),
                option: PermissionOption(optionId: "once", kind: .allowOnce, name: "Allow once")
            )
        }

        // Nothing was sent and the card is still pending.
        #expect(store.conversation(for: "s1").transcript.approvalCards.first?.state == .pending)
    }

    @Test func failedSendRollsTheCardBackToPending() async {
        let transport = MockWebSocketTransport()
        transport.sendError = ConnectionError.notConnected
        let store = makeStore(transport)
        store.applyPermissionRequest(makePermissionRequest(requestId: .number(0)))

        do {
            try await store.respondToPermission(
                sessionId: "s1",
                requestId: .number(0),
                option: PermissionOption(optionId: "once", kind: .allowOnce, name: "Allow once")
            )
            Issue.record("Expected error")
        } catch {
            // expected
        }

        // The user can retry.
        #expect(store.conversation(for: "s1").transcript.approvalCards.first?.state == .pending)
    }
}
