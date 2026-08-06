import Foundation
import Testing
@testable import ACPAgentCore

@Suite struct PromptTriggerTests {

    // MARK: - parse

    @Test func slashPrefixOpensCommandPanel() {
        #expect(PromptTrigger.parse(text: "/") == .commands(query: ""))
        #expect(PromptTrigger.parse(text: "/rev") == .commands(query: "rev"))
    }

    @Test func commandQueryWithWhitespaceHidesPanel() {
        // After picking a command the input is "/name " — the trailing space
        // marks the transition to argument typing, so the panel must close.
        #expect(PromptTrigger.parse(text: "/review ") == nil)
        #expect(PromptTrigger.parse(text: "/review main") == nil)
    }

    @Test func atPrefixOpensFilePanelWithRestAsQuery() {
        #expect(PromptTrigger.parse(text: "@") == .files(query: ""))
        #expect(PromptTrigger.parse(text: "@session") == .files(query: "session"))
    }

    @Test func plainTextHasNoTrigger() {
        #expect(PromptTrigger.parse(text: "hello") == nil)
        #expect(PromptTrigger.parse(text: "") == nil)
        #expect(PromptTrigger.parse(text: "  ") == nil)
        #expect(PromptTrigger.parse(text: "a/b") == nil)
    }

    // MARK: - filteredCommands

    @Test func emptyQueryKeepsAllCommands() {
        let commands = [
            AvailableCommand(name: "tdd", description: "Test-driven development."),
            AvailableCommand(name: "init", description: "guided AGENTS.md setup"),
        ]
        #expect(PromptTrigger.commands(query: "").filteredCommands(from: commands) == commands)
    }

    @Test func queryFiltersByName() {
        let commands = [
            AvailableCommand(name: "code-review", description: "Review the changes since a fixed point."),
            AvailableCommand(name: "review", description: "review changes [commit|branch|pr]"),
            AvailableCommand(name: "tdd", description: "Test-driven development."),
        ]
        let matches = PromptTrigger.commands(query: "rev").filteredCommands(from: commands)
        #expect(matches.map(\.name) == ["code-review", "review"])
    }

    @Test func queryFiltersByDescription() {
        let commands = [
            AvailableCommand(name: "implement", description: "Implement a piece of work."),
            AvailableCommand(name: "handoff", description: "Compact the conversation."),
        ]
        let matches = PromptTrigger.commands(query: "piece").filteredCommands(from: commands)
        #expect(matches.map(\.name) == ["implement"])
    }

    @Test func filesTriggerReturnsUnfilteredCommands() {
        // Filtering only applies to the commands trigger; a files trigger is
        // not a command query.
        let commands = [AvailableCommand(name: "init")]
        #expect(PromptTrigger.files(query: "x").filteredCommands(from: commands) == commands)
    }
}
