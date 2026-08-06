import Foundation
import Testing
@testable import ACPAgentCore

@Suite struct SessionUpdateTests {

    private func decode(_ json: String) throws -> SessionUpdateNotification {
        try JSONDecoder().decode(SessionUpdateNotification.self, from: Data(json.utf8))
    }

    @Test func decodesAgentMessageChunk() throws {
        let notification = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}}
        """#)

        #expect(notification.sessionId == "s1")
        #expect(notification.update == .agentMessageChunk(.text("hello")))
    }

    @Test func decodesThoughtAndUserChunks() throws {
        let thought = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking"}}}
        """#)
        #expect(thought.update == .agentThoughtChunk(.text("thinking")))

        let user = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"hi"}}}
        """#)
        #expect(user.update == .userMessageChunk(.text("hi")))
    }

    @Test func decodesToolCallWithAllFields() throws {
        let notification = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read server.ts","kind":"read","status":"pending","locations":[{"path":"/proj/src/server.ts","line":12}]}}
        """#)

        guard case .toolCall(let delta) = notification.update else {
            Issue.record("Expected toolCall, got \(notification.update)")
            return
        }
        #expect(delta.toolCallId == "t1")
        #expect(delta.title == "Read server.ts")
        #expect(delta.kind == .read)
        #expect(delta.status == .pending)
        #expect(delta.locations == ["/proj/src/server.ts"])
    }

    @Test func decodesToolCallUpdateWithOnlyStatus() throws {
        let notification = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed"}}
        """#)

        guard case .toolCallUpdate(let delta) = notification.update else {
            Issue.record("Expected toolCallUpdate, got \(notification.update)")
            return
        }
        #expect(delta.toolCallId == "t1")
        #expect(delta.status == .completed)
        #expect(delta.title == nil)
        #expect(delta.kind == nil)
        #expect(delta.content == nil)
    }

    @Test func unknownToolKindAndStatusFallBackToOther() throws {
        let notification = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Do it","kind":"teleport","status":"quantum"}}
        """#)

        guard case .toolCall(let delta) = notification.update else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(delta.kind == .other)
        #expect(delta.status == .pending)
    }

    @Test func decodesInProgressToolCallUpdate() throws {
        // ADR-005: opencode emits `in_progress` — without this case an
        // in-flight tool would decode to `.pending` and never complete.
        let notification = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"in_progress"}}
        """#)

        guard case .toolCallUpdate(let delta) = notification.update else {
            Issue.record("Expected toolCallUpdate")
            return
        }
        #expect(delta.status == .inProgress)
        #expect(delta.status?.displayName == "In Progress")
        #expect(delta.status?.isTerminal == false)
    }

    @Test func decodesFailedToolCallUpdate() throws {
        // ADR-005: a rejected permission fails the gated tool with `failed`.
        let notification = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"failed"}}
        """#)

        guard case .toolCallUpdate(let delta) = notification.update else {
            Issue.record("Expected toolCallUpdate")
            return
        }
        #expect(delta.status == .failed)
        #expect(delta.status?.displayName == "Failed")
        #expect(delta.status?.isTerminal == true)
    }

    @Test func decodesToolCallContentAsText() throws {
        let notification = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","content":[{"type":"content","content":{"type":"text","text":"line one"}},{"type":"content","content":{"type":"text","text":"line two"}}]}}
        """#)

        guard case .toolCallUpdate(let delta) = notification.update else {
            Issue.record("Expected toolCallUpdate")
            return
        }
        #expect(delta.content == ["line one", "line two"])
    }

    @Test func decodesDiffToolCallContentStructurally() throws {
        // Live-verified (issue #9, opencode 1.18.13): edit tools carry
        // `{type: "diff", path, oldText, newText}` blocks on the final
        // `tool_call_update`; the unified diff is computed client-side.
        let notification = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","content":[{"type":"diff","path":"/proj/a.txt","oldText":"hello","newText":"hello world"}]}}
        """#)

        guard case .toolCallUpdate(let delta) = notification.update else {
            Issue.record("Expected toolCallUpdate")
            return
        }
        #expect(delta.content == [])
        let diff = try #require(delta.diffs?.first)
        #expect(diff.path == "/proj/a.txt")
        #expect(diff.oldText == "hello")
        #expect(diff.newText == "hello world")
        #expect(diff.addedCount == 1)
        #expect(diff.removedCount == 1)
        #expect(diff.lines == [
            DiffLine(kind: .hunkHeader, text: "@@ -1 +1 @@"),
            DiffLine(kind: .deletion, text: "hello"),
            DiffLine(kind: .addition, text: "hello world"),
        ])
    }

    @Test func decodesMixedTextAndDiffContentBlocks() throws {
        let notification = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","content":[{"type":"content","content":{"type":"text","text":"Edit applied successfully."}},{"type":"diff","path":"/p/a.txt","oldText":"a","newText":"b"}]}}
        """#)

        guard case .toolCallUpdate(let delta) = notification.update else {
            Issue.record("Expected toolCallUpdate")
            return
        }
        #expect(delta.content == ["Edit applied successfully."])
        #expect(delta.diffs?.count == 1)
        #expect(delta.diffs?.first?.path == "/p/a.txt")
    }

    @Test func diffBlockWithoutNewTextIsAllDeletions() throws {
        let notification = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","content":[{"type":"diff","path":"/p/a.txt","oldText":"gone"}]}}
        """#)

        guard case .toolCallUpdate(let delta) = notification.update else {
            Issue.record("Expected toolCallUpdate")
            return
        }
        let diff = try #require(delta.diffs?.first)
        #expect(diff.newText == "")
        #expect(diff.addedCount == 0)
        #expect(diff.removedCount == 1)
    }

    @Test func decodesPlanEntries() throws {
        let notification = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"plan","entries":[{"content":"Read code","priority":"high","status":"completed"},{"content":"Write code","priority":"medium","status":"pending"}]}}
        """#)

        guard case .plan(let entries) = notification.update else {
            Issue.record("Expected plan, got \(notification.update)")
            return
        }
        #expect(entries.count == 2)
        #expect(entries[0].content == "Read code")
        #expect(entries[0].status == .completed)
        #expect(entries[1].status == .pending)
    }

    @Test func decodesAvailableCommandsUpdate() throws {
        // Live-verified wire shape (ADR-005): opencode pushes the slash-command
        // directory after session/new; client-side commands are already
        // filtered out by the agent.
        let notification = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"available_commands_update","availableCommands":[
          {"name":"code-review","description":"Review the changes since a fixed point."},
          {"name":"init","description":"guided AGENTS.md setup"}
        ]}}
        """#)

        guard case .availableCommands(let commands) = notification.update else {
            Issue.record("Expected availableCommands, got \(notification.update)")
            return
        }
        #expect(commands.count == 2)
        #expect(commands[0].name == "code-review")
        #expect(commands[0].description == "Review the changes since a fixed point.")
        #expect(commands[1].name == "init")
        #expect(commands[1].description == "guided AGENTS.md setup")
    }

    @Test func availableCommandsUpdateRoundTripsThroughEncoder() throws {
        let notification = SessionUpdateNotification(
            sessionId: "s1",
            update: .availableCommands([
                AvailableCommand(name: "tdd", description: "Test-driven development."),
                AvailableCommand(name: "init"),
            ])
        )

        let data = try JSONEncoder().encode(notification)
        let decoded = try JSONDecoder().decode(SessionUpdateNotification.self, from: data)

        #expect(decoded == notification)
        guard case .availableCommands(let commands) = decoded.update else {
            Issue.record("Expected availableCommands")
            return
        }
        #expect(commands[0] == AvailableCommand(name: "tdd", description: "Test-driven development."))
        #expect(commands[1] == AvailableCommand(name: "init", description: nil))
    }

    @Test func unrecognisedVariantDecodesAsUnsupported() throws {
        let notification = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"current_mode_update","currentModeId":"build"}}
        """#)
        #expect(notification.update == .unsupported("current_mode_update"))
    }

    @Test func resourceAndLinkContentBlocksCarryDisplayText() throws {
        let resource = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"resource","resource":{"uri":"file:///proj/a.txt","text":"file body"}}}}
        """#)
        #expect(resource.update.contentBlock?.displayText == "file body")

        let link = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"user_message_chunk","content":{"type":"resource_link","uri":"file:///proj/a.txt","name":"a.txt"}}}
        """#)
        #expect(link.update.contentBlock?.displayText == "a.txt")

        let image = try decode(#"""
        {"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"image","mimeType":"image/png","data":"AAAA"}}}
        """#)
        #expect(image.update.contentBlock?.displayText == "[image]")
    }
}
