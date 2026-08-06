import Foundation
import Testing
@testable import ACPAgentCore

@Suite struct SessionTranscriptTests {

    @Test func agentChunksAppendToSameMessage() {
        var transcript = SessionTranscript()

        transcript.apply(.agentMessageChunk(.text("Hello ")))
        transcript.apply(.agentMessageChunk(.text("world")))

        #expect(transcript.messages.count == 1)
        #expect(transcript.messages[0].role == .assistant)
        #expect(transcript.messages[0].text == "Hello world")
        #expect(!transcript.messages[0].isComplete)
    }

    @Test func userChunkCreatesUserMessage() {
        var transcript = SessionTranscript()

        transcript.apply(.userMessageChunk(.text("Hi there")))

        #expect(transcript.messages.count == 1)
        #expect(transcript.messages[0].role == .user)
        #expect(transcript.messages[0].text == "Hi there")
    }

    @Test func thoughtChunkAppearsAsThoughtMessage() {
        var transcript = SessionTranscript()

        transcript.apply(.agentThoughtChunk(.text("Let me think")))

        #expect(transcript.messages.count == 1)
        #expect(transcript.messages[0].role == .thought)
        #expect(transcript.messages[0].text == "Let me think")
    }

    @Test func newAgentMessageAfterUserMessage() {
        var transcript = SessionTranscript()

        transcript.apply(.userMessageChunk(.text("Hi")))
        transcript.apply(.agentMessageChunk(.text("Hello")))
        transcript.apply(.agentMessageChunk(.text(" there")))

        #expect(transcript.messages.count == 2)
        #expect(transcript.messages[0].role == .user)
        #expect(transcript.messages[0].text == "Hi")
        #expect(transcript.messages[1].role == .assistant)
        #expect(transcript.messages[1].text == "Hello there")
    }

    @Test func userInterruptsAgentCreatesNewMessage() {
        var transcript = SessionTranscript()

        transcript.apply(.agentMessageChunk(.text("Let me ")))
        transcript.apply(.agentMessageChunk(.text("explain")))
        transcript.apply(.userMessageChunk(.text("Stop")))

        #expect(transcript.messages.count == 2)
        #expect(transcript.messages[0].role == .assistant)
        #expect(transcript.messages[0].text == "Let me explain")
        #expect(transcript.messages[1].role == .user)
        #expect(transcript.messages[1].text == "Stop")
    }

    @Test func secondAgentTurnAfterUser() {
        var transcript = SessionTranscript()

        transcript.apply(.userMessageChunk(.text("Q1")))
        transcript.apply(.agentMessageChunk(.text("A1")))
        transcript.apply(.userMessageChunk(.text("Q2")))
        transcript.apply(.agentMessageChunk(.text("A2")))

        #expect(transcript.messages.count == 4)
        #expect(transcript.messages[0].text == "Q1")
        #expect(transcript.messages[1].text == "A1")
        #expect(transcript.messages[2].text == "Q2")
        #expect(transcript.messages[3].text == "A2")
    }

    @Test func toolCallCreatesToolCard() {
        var transcript = SessionTranscript()

        transcript.apply(.toolCall(.init(
            toolCallId: "tc1",
            title: "Read foo.swift",
            kind: .read,
            status: .pending,
            locations: ["/proj/foo.swift"]
        )))

        #expect(transcript.toolCalls.count == 1)
        let tc = transcript.toolCalls[0]
        #expect(tc.id == "tc1")
        #expect(tc.title == "Read foo.swift")
        #expect(tc.kind == .read)
        #expect(tc.status == .pending)
        #expect(tc.locations == ["/proj/foo.swift"])
    }

    @Test func toolCallUpdateMergesIntoExisting() {
        var transcript = SessionTranscript()

        transcript.apply(.toolCall(.init(
            toolCallId: "tc1",
            title: "Bash command",
            kind: .bash,
            status: .pending
        )))
        transcript.apply(.toolCallUpdate(.init(
            toolCallId: "tc1",
            status: .running
        )))

        #expect(transcript.toolCalls.count == 1)
        #expect(transcript.toolCalls[0].status == .running)
        #expect(transcript.toolCalls[0].title == "Bash command")
    }

    @Test func toolCallUpdateAppendsContent() {
        var transcript = SessionTranscript()

        transcript.apply(.toolCall(.init(
            toolCallId: "tc1",
            title: "Read",
            kind: .read,
            status: .running
        )))
        transcript.apply(.toolCallUpdate(.init(
            toolCallId: "tc1",
            content: ["line 1"]
        )))
        transcript.apply(.toolCallUpdate(.init(
            toolCallId: "tc1",
            content: ["line 2"]
        )))

        #expect(transcript.toolCalls[0].content == ["line 1", "line 2"])
    }

    @Test func toolCallUpdateCompletedKeepsKind() {
        var transcript = SessionTranscript()

        transcript.apply(.toolCall(.init(
            toolCallId: "tc1",
            title: "Edit",
            kind: .edit,
            status: .running
        )))
        transcript.apply(.toolCallUpdate(.init(
            toolCallId: "tc1",
            status: .completed
        )))

        #expect(transcript.toolCalls[0].status == .completed)
        #expect(transcript.toolCalls[0].kind == .edit)
    }

    @Test func unsupportedUpdatesAreIgnored() {
        var transcript = SessionTranscript()

        transcript.apply(.unsupported("something_weird"))

        #expect(transcript.messages.isEmpty)
        #expect(transcript.toolCalls.isEmpty)
    }

    @Test func planEntriesAreStored() {
        var transcript = SessionTranscript()

        transcript.apply(.plan([
            PlanEntry(content: "Step 1", status: .completed),
            PlanEntry(content: "Step 2", status: .inProgress),
        ]))

        #expect(transcript.planEntries?.count == 2)
        #expect(transcript.planEntries?[0].content == "Step 1")
        #expect(transcript.planEntries?[1].status == .inProgress)
    }

    @Test func planIsReplacedOnSubsequentPlanUpdate() {
        var transcript = SessionTranscript()

        transcript.apply(.plan([
            PlanEntry(content: "Old", status: .pending),
        ]))
        transcript.apply(.plan([
            PlanEntry(content: "New", status: .completed),
        ]))

        #expect(transcript.planEntries?.count == 1)
        #expect(transcript.planEntries?[0].content == "New")
    }

    @Test func serverEchoOfLocalUserMessageDoesNotDuplicateTheBubble() {
        var transcript = SessionTranscript()

        transcript.appendLocalUserMessage("explain this")
        transcript.apply(.userMessageChunk(.text("explain this")))

        #expect(transcript.messages.count == 1)
        #expect(transcript.messages[0].role == .user)
        #expect(transcript.messages[0].text == "explain this")
    }

    @Test func userChunkWithDifferentTextStillGetsItsOwnBubble() {
        var transcript = SessionTranscript()

        transcript.appendLocalUserMessage("first")
        transcript.apply(.userMessageChunk(.text("something else")))

        #expect(transcript.messages.count == 2)
        #expect(transcript.messages[0].text == "first")
        #expect(transcript.messages[1].text == "something else")
    }

    @Test func echoStreamedInChunksStillFillsOneBubble() {
        var transcript = SessionTranscript()

        transcript.appendLocalUserMessage("hello world")
        transcript.apply(.userMessageChunk(.text("hello")))
        transcript.apply(.userMessageChunk(.text("hello world")))

        #expect(transcript.messages.count == 1)
        #expect(transcript.messages[0].text == "hello world")
    }

    @Test func agentReplyAfterLocalUserMessageStartsANewBubble() {
        var transcript = SessionTranscript()

        transcript.appendLocalUserMessage("question")
        transcript.apply(.agentMessageChunk(.text("answer")))

        #expect(transcript.messages.count == 2)
        #expect(transcript.messages[0].role == .user)
        #expect(transcript.messages[1].role == .assistant)
        #expect(transcript.messages[1].text == "answer")
    }

    @Test func isGeneratingReflectsActiveToolOrStreaming() {
        var transcript = SessionTranscript()
        #expect(!transcript.isGenerating)

        transcript.apply(.agentMessageChunk(.text("hi")))
        #expect(transcript.isGenerating)

        transcript.apply(.toolCall(.init(toolCallId: "t1", title: "Run", kind: .bash, status: .running)))
        #expect(transcript.isGenerating)

        transcript.apply(.toolCallUpdate(.init(toolCallId: "t1", status: .completed)))
        #expect(transcript.isGenerating)

        transcript.markIdle()
        #expect(!transcript.isGenerating)
    }

    // MARK: - Permission approvals

    private func makeRequest(requestId: Int = 0) -> PermissionRequest {
        PermissionRequest(
            sessionId: "s1",
            toolCall: PermissionToolCall(
                toolCallId: "call_\(requestId)",
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
    }

    @Test func approvalRequestAppendsPendingCard() {
        var transcript = SessionTranscript()
        var request = makeRequest(requestId: 3)
        request.requestId = .number(3)

        transcript.applyApprovalRequest(request)

        #expect(transcript.approvalCards.count == 1)
        let card = transcript.approvalCards[0]
        #expect(card.id == "perm:3")
        #expect(card.requestId == .number(3))
        #expect(card.toolCall.title == "curl -s http://example.com")
        #expect(card.toolCall.locations == ["/etc/hosts"])
        #expect(card.options.count == 3)
        #expect(card.state == .pending)
        #expect(transcript.items.first == .approval(card))
    }

    @Test func duplicateApprovalRequestKeepsFirstCard() {
        var transcript = SessionTranscript()
        var request = makeRequest(requestId: 1)
        request.requestId = .number(1)

        transcript.applyApprovalRequest(request)
        transcript.applyApprovalRequest(request)

        #expect(transcript.approvalCards.count == 1)
    }

    @Test func approvalCardPausesTheSpinner() {
        var transcript = SessionTranscript()
        transcript.apply(.agentMessageChunk(.text("working")))
        #expect(transcript.isGenerating)

        var request = makeRequest(requestId: 1)
        request.requestId = .number(1)
        transcript.applyApprovalRequest(request)

        // The agent is blocked on the user's choice, not streaming.
        #expect(!transcript.isGenerating)
    }

    @Test func resolveApprovalTransitionsToApproved() {
        var transcript = SessionTranscript()
        var request = makeRequest(requestId: 2)
        request.requestId = .number(2)
        transcript.applyApprovalRequest(request)

        let transitioned = transcript.resolveApproval(requestId: .number(2), state: .approved(optionId: "once"))

        #expect(transitioned)
        #expect(transcript.approvalCards[0].state == .approved(optionId: "once"))
        #expect(transcript.approvalCards[0].state.isTerminal)
    }

    @Test func resolveApprovalTransitionsToRejected() {
        var transcript = SessionTranscript()
        var request = makeRequest(requestId: 2)
        request.requestId = .number(2)
        transcript.applyApprovalRequest(request)

        let transitioned = transcript.resolveApproval(requestId: .number(2), state: .rejected)

        #expect(transitioned)
        #expect(transcript.approvalCards[0].state == .rejected)
    }

    @Test func resolveApprovalOnTerminalCardIsRefused() {
        var transcript = SessionTranscript()
        var request = makeRequest(requestId: 2)
        request.requestId = .number(2)
        transcript.applyApprovalRequest(request)
        _ = transcript.resolveApproval(requestId: .number(2), state: .approved(optionId: "once"))

        // A second answer (double-tap or another device) must not change state.
        let second = transcript.resolveApproval(requestId: .number(2), state: .rejected)

        #expect(!second)
        #expect(transcript.approvalCards[0].state == .approved(optionId: "once"))
    }

    @Test func resolveApprovalForUnknownRequestIsRefused() {
        var transcript = SessionTranscript()

        let transitioned = transcript.resolveApproval(requestId: .number(99), state: .rejected)

        #expect(!transitioned)
        #expect(transcript.approvalCards.isEmpty)
    }

    @Test func revertApprovalRollsTerminalCardBackToPending() {
        var transcript = SessionTranscript()
        var request = makeRequest(requestId: 2)
        request.requestId = .number(2)
        transcript.applyApprovalRequest(request)
        _ = transcript.resolveApproval(requestId: .number(2), state: .approved(optionId: "once"))

        let reverted = transcript.revertApproval(requestId: .number(2))

        #expect(reverted)
        #expect(transcript.approvalCards[0].state == .pending)
    }

    @Test func revertApprovalOnPendingCardIsRefused() {
        var transcript = SessionTranscript()
        var request = makeRequest(requestId: 2)
        request.requestId = .number(2)
        transcript.applyApprovalRequest(request)

        let reverted = transcript.revertApproval(requestId: .number(2))

        #expect(!reverted)
        #expect(transcript.approvalCards[0].state == .pending)
    }

    @Test func markIdleDoesNotClearApprovalCards() {
        var transcript = SessionTranscript()
        var request = makeRequest(requestId: 1)
        request.requestId = .number(1)
        transcript.applyApprovalRequest(request)

        transcript.markIdle()

        #expect(transcript.approvalCards.count == 1)
        #expect(transcript.approvalCards[0].state == .pending)
    }
}
