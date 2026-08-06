import Foundation
import Testing
@testable import ACPAgentCore

@Suite struct UnifiedDiffTests {

    private func render(_ old: [String], _ new: [String], context: Int = 3) -> DiffRender {
        UnifiedDiff.render(old: old, new: new, contextLines: context)
    }

    @Test func identicalInputsProduceNoDiff() {
        let result = render(["a", "b"], ["a", "b"])
        #expect(result.lines.isEmpty)
        #expect(result.addedCount == 0)
        #expect(result.removedCount == 0)
    }

    @Test func newFileShowsEveryLineAsAddition() {
        let result = render([], ["a", "b"])
        #expect(result.lines.map(\.kind) == [.hunkHeader, .addition, .addition])
        #expect(result.lines[0].text == "@@ -0,0 +1,2 @@")
        #expect(result.lines[1].text == "a")
        #expect(result.lines[2].text == "b")
        #expect(result.addedCount == 2)
        #expect(result.removedCount == 0)
    }

    @Test func deletedFileShowsEveryLineAsDeletion() {
        let result = render(["a", "b"], [])
        #expect(result.lines.map(\.kind) == [.hunkHeader, .deletion, .deletion])
        #expect(result.lines[0].text == "@@ -1,2 +0,0 @@")
        #expect(result.removedCount == 2)
    }

    @Test func singleLineReplacementUsesOneHunk() {
        let result = render(["hello"], ["hello world"])
        #expect(result.lines == [
            DiffLine(kind: .hunkHeader, text: "@@ -1 +1 @@"),
            DiffLine(kind: .deletion, text: "hello"),
            DiffLine(kind: .addition, text: "hello world"),
        ])
        #expect(result.addedCount == 1)
        #expect(result.removedCount == 1)
    }

    @Test func modificationIsSurroundedByContext() {
        let result = render(["a", "b", "c"], ["a", "x", "c"])
        #expect(result.lines.map(\.kind) == [.hunkHeader, .context, .deletion, .addition, .context])
        #expect(result.lines[0].text == "@@ -1,3 +1,3 @@")
        #expect(result.lines[1].text == "a")
        #expect(result.lines[2].text == "b")
        #expect(result.lines[3].text == "x")
        #expect(result.lines[4].text == "c")
    }

    @Test func distantChangesSplitIntoTwoHunks() {
        var old = (1...15).map { "L\($0)" }
        var new = old
        new[1] = "N2"
        new[10] = "N11"
        let result = render(old, new)
        #expect(result.lines.filter { $0.kind == .hunkHeader }.map(\.text) == ["@@ -1,5 +1,5 @@", "@@ -8,7 +8,7 @@"])
        #expect(result.lines.map(\.kind) == [
            .hunkHeader,
            .context, .deletion, .addition, .context, .context, .context,
            .hunkHeader,
            .context, .context, .context, .deletion, .addition, .context, .context, .context,
        ])
    }

    @Test func nearbyChangesMergeIntoSingleHunk() {
        var old = (1...10).map { "L\($0)" }
        var new = old
        new[1] = "N2"
        new[5] = "N6"
        let result = render(old, new)
        #expect(result.lines.filter { $0.kind == .hunkHeader }.map(\.text) == ["@@ -1,9 +1,9 @@"])
        #expect(result.addedCount == 2)
        #expect(result.removedCount == 2)
    }

    @Test func trailingContextRespectsFileLength() {
        let result = render(["a", "b", "c", "d"], ["a", "b", "c", "d2"])
        #expect(result.lines.first?.text == "@@ -1,4 +1,4 @@")
    }

    @Test func leadingContextRespectsFileStart() {
        let result = render(["a", "b", "c", "d"], ["a2", "b", "c", "d"])
        #expect(result.lines.first?.text == "@@ -1,4 +1,4 @@")
    }

    @Test func stringBasedRenderSplitsLines() {
        let result = UnifiedDiff.render(old: "hello", new: "hello world")
        #expect(result.lines.count == 3)
        #expect(result.lines[1] == DiffLine(kind: .deletion, text: "hello"))
        #expect(result.lines[2] == DiffLine(kind: .addition, text: "hello world"))
    }

    @Test func scatteredEditsBeyondOldTraceBudgetStayGranular() {
        // 500 middle lines with every other line changed: an edit script of
        // 500 steps that the old trace-based engine would have degraded to a
        // whole-file replacement. The linear-space engine must keep the
        // unchanged lines as context instead of deleting/inserting them.
        var old = (1...500).map { "L\($0)" }
        var new = old
        for i in stride(from: 1, through: 499, by: 2) { new[i] = "N\(i)" }

        let result = render(old, new)
        #expect(result.addedCount == 250)
        #expect(result.removedCount == 250)
        #expect(result.lines.contains { $0.kind == .context })
        // A full-middle replacement would be ~1000 lines; context keeps it under.
        #expect(result.lines.count < 900)
    }

    @Test func identicalLongMiddleStaysContextOnly() {
        let old = (1...400).map { "L\($0)" }
        let result = render(old, old)
        #expect(result.lines.isEmpty)
    }

    @Test func fileDiffComputesCountsAndLines() {
        let diff = FileDiff(path: "/proj/a.txt", oldText: "hello", newText: "hello world")
        #expect(diff.path == "/proj/a.txt")
        #expect(diff.oldText == "hello")
        #expect(diff.newText == "hello world")
        #expect(diff.addedCount == 1)
        #expect(diff.removedCount == 1)
        #expect(diff.lines.last == DiffLine(kind: .addition, text: "hello world"))
    }

    @Test func fileDiffWithNilOldTextIsAllAdditions() {
        let diff = FileDiff(path: "/proj/new.swift", oldText: nil, newText: "let x = 1\nlet y = 2")
        #expect(diff.addedCount == 2)
        #expect(diff.removedCount == 0)
        #expect(diff.lines.first?.text == "@@ -0,0 +1,2 @@")
    }
}
