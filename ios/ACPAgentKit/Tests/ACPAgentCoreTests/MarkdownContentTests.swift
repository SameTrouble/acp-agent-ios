import Foundation
import Testing
@testable import ACPAgentCore

@Suite struct MarkdownContentTests {

    // MARK: - 无代码块

    @Test func plainTextYieldsSingleTextSegment() {
        let segments = MarkdownContent.segments(from: "Hello world")

        #expect(segments.count == 1)
        guard let attr = textSegment(segments) else { return }
        #expect(String(attr.characters) == "Hello world")
    }

    @Test func emptyTextYieldsSingleTextSegment() {
        let segments = MarkdownContent.segments(from: "")

        #expect(segments.count == 1)
        guard let attr = textSegment(segments) else { return }
        #expect(String(attr.characters) == "")
    }

    // MARK: - fenced code block

    @Test func fencedCodeBlockBecomesCodeSegment() {
        let md = "Before.\n\n```swift\nlet x = 1\nprint(x)\n```\n\nAfter."

        let segments = MarkdownContent.segments(from: md)

        #expect(segments.count == 3)
        guard textSegment(segments, at: 0) != nil, textSegment(segments, at: 2) != nil else { return }
        guard let block = codeBlock(segments, at: 1) else { return }
        #expect(block.content == "let x = 1\nprint(x)\n")
        #expect(block.languageHint == "swift")
    }

    @Test func codeBlockWithoutLanguageHint() {
        let segments = MarkdownContent.segments(from: "```\nplain code\n```")

        guard let block = codeBlock(segments) else { return }
        #expect(block.content == "plain code\n")
        #expect(block.languageHint == nil)
    }

    @Test func tildesFenceIsSupported() {
        let segments = MarkdownContent.segments(from: "~~~python\nprint(1)\n~~~")

        guard let block = codeBlock(segments) else { return }
        #expect(block.content == "print(1)\n")
        #expect(block.languageHint == "python")
    }

    @Test func languageHintTakesFirstWordOfInfoString() {
        let segments = MarkdownContent.segments(from: "```swift with extra words\ncode\n```")

        guard let block = codeBlock(segments) else { return }
        #expect(block.languageHint == "swift")
    }

    @Test func longerClosingFenceIsAccepted() {
        let segments = MarkdownContent.segments(from: "```\ncode\n````\n")

        guard let block = codeBlock(segments) else { return }
        #expect(block.content == "code\n")
    }

    @Test func crlfLineEndingsDoNotLeakCarriageReturns() {
        let segments = MarkdownContent.segments(from: "```\r\ncode line\r\n```\r\n")

        guard let block = codeBlock(segments) else { return }
        #expect(block.content == "code line\n")
    }

    @Test func multipleCodeBlocksAlternateWithText() {
        let md = "a\n```\n1\n```\nb\n```\n2\n```\nc"

        let segments = MarkdownContent.segments(from: md)

        #expect(segments.count == 5)
        guard textSegment(segments, at: 0) != nil, textSegment(segments, at: 2) != nil, textSegment(segments, at: 4) != nil else { return }
        #expect(codeBlock(segments, at: 1)?.content == "1\n")
        #expect(codeBlock(segments, at: 3)?.content == "2\n")
    }

    @Test func unterminatedFenceConsumesTheRestOfTheText() {
        let md = "Before.\n```\nunclosed"

        let segments = MarkdownContent.segments(from: md)

        #expect(segments.count == 2)
        guard textSegment(segments, at: 0) != nil else { return }
        guard let block = codeBlock(segments, at: 1) else { return }
        #expect(block.content == "unclosed\n")
    }

    @Test func codeBlockAtTheStartAndEndOfTheText() {
        let md = "```swift\nlet x = 1\n```\nAnd now this."

        let segments = MarkdownContent.segments(from: md)

        #expect(segments.count == 2)
        guard let block = codeBlock(segments, at: 0) else { return }
        #expect(block.content == "let x = 1\n")
        #expect(block.languageHint == "swift")
    }

    // MARK: - 既有 markdown 渲染不回退

    @Test func inlineCodeStaysInsideTheTextSegment() {
        let md = "Use `let x = 1` inline."

        let segments = MarkdownContent.segments(from: md)

        #expect(segments.count == 1)
        guard let attr = textSegment(segments) else { return }
        let codeRuns = attr.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        #expect(codeRuns.count == 1)
        #expect(String(attr[codeRuns[0].range].characters) == "let x = 1")
    }

    @Test func boldAndListSurviveInTextSegments() {
        let md = "- **bold** item\n- plain item"

        let segments = MarkdownContent.segments(from: md)

        guard let attr = textSegment(segments) else { return }
        let boldRuns = attr.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(!boldRuns.isEmpty)
        #expect(boldRuns.allSatisfy { String(attr[$0.range].characters) == "bold" })
        #expect(attr.runs.contains { $0.presentationIntent != nil })
    }

    @Test func codeBlockContentIsNotParsedAsMarkdown() {
        let md = "```\n**not bold**\n```"

        let segments = MarkdownContent.segments(from: md)

        guard let block = codeBlock(segments) else { return }
        #expect(block.content == "**not bold**\n")
    }

    @Test func textSegmentsRejoinParagraphsWithoutLosingNewlines() {
        let md = "First paragraph.\n\nSecond paragraph."

        let segments = MarkdownContent.segments(from: md)

        guard let attr = textSegment(segments) else { return }
        let characters = String(attr.characters)
        #expect(characters.contains("First paragraph."))
        #expect(characters.contains("Second paragraph."))
    }

    // MARK: - helpers

    private func textSegment(_ segments: [MarkdownSegment], at index: Int = 0) -> AttributedString? {
        guard segments.indices.contains(index) else {
            Issue.record("No segment at index \(index)")
            return nil
        }
        guard case .text(let attr) = segments[index] else {
            Issue.record("Expected a text segment at index \(index)")
            return nil
        }
        return attr
    }

    private func codeBlock(
        _ segments: [MarkdownSegment],
        at index: Int = 0
    ) -> (content: String, languageHint: String?)? {
        guard segments.indices.contains(index) else {
            Issue.record("No segment at index \(index)")
            return nil
        }
        guard case .codeBlock(let content, let languageHint) = segments[index] else {
            Issue.record("Expected a code block segment at index \(index)")
            return nil
        }
        return (content, languageHint)
    }
}
