import Foundation
import Testing
@testable import ACPAgentCore

@Suite struct SyntaxHighlighterTests {

    private func matches(_ text: String, _ language: SyntaxLanguage, kind: SyntaxTokenKind) -> [String] {
        SyntaxHighlighter.tokens(in: text, language: language)
            .filter { $0.kind == kind }
            .map { String(text[$0.range]) }
    }

    @Test func detectsLanguageFromPath() {
        #expect(SyntaxLanguage.detect(from: "/proj/src/App.swift") == .swift)
        #expect(SyntaxLanguage.detect(from: "index.tsx") == .typescript)
        #expect(SyntaxLanguage.detect(from: "main.py") == .python)
        #expect(SyntaxLanguage.detect(from: "server.go") == .go)
        #expect(SyntaxLanguage.detect(from: "Main.java") == .java)
        #expect(SyntaxLanguage.detect(from: "data.json") == .json)
        #expect(SyntaxLanguage.detect(from: "setup.sh") == .shell)
        #expect(SyntaxLanguage.detect(from: "README.md") == .markdown)
        #expect(SyntaxLanguage.detect(from: "Makefile") == .plain)
        #expect(SyntaxLanguage.detect(from: "unknown.xyz") == .plain)
    }

    @Test func plainLanguageYieldsNoTokens() {
        #expect(SyntaxHighlighter.tokens(in: "let x = 42 // hi", language: .plain).isEmpty)
        #expect(SyntaxHighlighter.tokens(in: "", language: .swift).isEmpty)
    }

    @Test func swiftKeywordsNumbersAndComments() {
        let text = "let count = 42 // total"
        #expect(matches(text, .swift, kind: .keyword) == ["let"])
        #expect(matches(text, .swift, kind: .number) == ["42"])
        #expect(matches(text, .swift, kind: .comment) == ["// total"])
    }

    @Test func swiftFunctionsTypesAndStrings() {
        let text = #"func greet(name: String) -> Int { return 42 }"#
        #expect(matches(text, .swift, kind: .keyword) == ["func", "return"])
        #expect(matches(text, .swift, kind: .function) == ["greet"])
        #expect(matches(text, .swift, kind: .type) == ["String", "Int"])
        #expect(matches(text, .swift, kind: .number) == ["42"])

        let stringText = #"let s = "hello world""#
        #expect(matches(stringText, .swift, kind: .string) == ["\"hello world\""])
    }

    @Test func keywordsDoNotMatchInsideIdentifiers() {
        let text = "let lettuce = variable"
        #expect(matches(text, .swift, kind: .keyword) == ["let"])
    }

    @Test func numberVariants() {
        #expect(matches("0xFF 3.14 1_000 42", .swift, kind: .number) == ["0xFF", "3.14", "1_000", "42"])
    }

    @Test func typescriptTemplateStringsAndKeywords() {
        let text = #"const name = `hello ${user}`"#
        #expect(matches(text, .typescript, kind: .keyword) == ["const"])
        #expect(matches(text, .typescript, kind: .string) == ["`hello ${user}`"])
    }

    @Test func pythonCommentsStringsAndDefs() {
        let text = #"def f(x):  # doc"#
        #expect(matches(text, .python, kind: .keyword) == ["def"])
        #expect(matches(text, .python, kind: .function) == ["f"])
        #expect(matches(text, .python, kind: .comment) == ["# doc"])
    }

    @Test func hashCommentsInsideStringsAreNotComments() {
        let text = #"x = "a # b"  # real"#
        let result = SyntaxHighlighter.tokens(in: text, language: .python)
        let comments = result.filter { $0.kind == .comment }.map { String(text[$0.range]) }
        #expect(comments == ["# real"])
        #expect(result.contains { $0.kind == .string })
    }

    @Test func jsonKeysStringsAndLiterals() {
        let text = #"{"ok": true, "n": 3}"#
        #expect(matches(text, .json, kind: .string).count == 2)
        #expect(matches(text, .json, kind: .keyword) == ["true"])
        #expect(matches(text, .json, kind: .number) == ["3"])
    }

    @Test func goPackageAndComment() {
        let text = "package main // entry"
        #expect(matches(text, .go, kind: .keyword) == ["package"])
        #expect(matches(text, .go, kind: .comment) == ["// entry"])
    }

    @Test func markdownHeadingsAndInlineCode() {
        let text = "## Title"
        #expect(matches(text, .markdown, kind: .keyword) == ["## "])

        let code = "use `code` here"
        #expect(matches(code, .markdown, kind: .string) == ["`code`"])
    }
}
