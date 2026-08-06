import Foundation

/// 一条消息经 markdown 分段后的一个片段。
///
/// fenced code block 被单独抽出为 `codeBlock`，其余内容保持为富文本 `text`，
/// 因此列表、加粗、斜体、行内 code 等既有渲染行为不受影响。
public enum MarkdownSegment: Equatable {
    /// 富文本段：由 `AttributedString(markdown:)` 解析，保留 presentationIntent
    /// 与 inlinePresentationIntent（列表、加粗、斜体、行内 code 等）。
    case text(AttributedString)
    /// fenced code block：内容是未解析的纯文本，语言提示来自开围栏。
    case codeBlock(content: String, languageHint: String?)
}

/// 把 markdown 文本切分为普通富文本段与 fenced code block 段。
///
/// 识别规则是 CommonMark fenced code block 的常用子集：开围栏为行首（允许
/// 0-3 个空格缩进）的连续 3 个以上 `` ` `` 或 `~`；结束围栏为同字符、长度
/// 不小于开围栏、其后仅含空白的行；未闭合的围栏会吞掉剩余全部文本（与
/// CommonMark 一致）。列表项内嵌的围栏（更深缩进）不属于本子集。代码块
/// 内容不做 markdown 解析（不做语法高亮、不识别块内标记）。
public enum MarkdownContent {

    /// 与既有渲染管线一致的解析选项（全语法 + 扩展属性）。
    private static let parsingOptions: AttributedString.MarkdownParsingOptions = {
        var options = AttributedString.MarkdownParsingOptions()
        options.allowsExtendedAttributes = true
        options.interpretedSyntax = .full
        return options
    }()

    /// 将 markdown 文本分段：fenced code block 与其余内容交替出现。
    ///
    /// 非代码内容仍由 `AttributedString(markdown:)` 解析，解析失败时回退为
    /// 原样纯文本，与既有行为一致。
    public static func segments(from text: String) -> [MarkdownSegment] {
        let blocks = fencedBlocks(in: text)
        guard !blocks.isEmpty else {
            return [.text(parse(text))]
        }

        var segments: [MarkdownSegment] = []
        var cursor = text.startIndex
        for block in blocks {
            if cursor < block.range.lowerBound {
                let slice = String(text[cursor..<block.range.lowerBound])
                if !slice.isEmpty {
                    segments.append(.text(parse(slice)))
                }
            }
            segments.append(.codeBlock(content: block.content, languageHint: block.languageHint))
            cursor = block.range.upperBound
        }
        if cursor < text.endIndex {
            let slice = String(text[cursor...])
            if !slice.isEmpty {
                segments.append(.text(parse(slice)))
            }
        }
        return segments
    }

    // MARK: - Fenced code block scanning

    private struct FencedBlock {
        /// 开围栏行首到结束围栏行尾（含换行）的完整范围。
        let range: Range<String.Index>
        /// 围栏之间的内容（保留换行，尾部保留一个换行符）。
        let content: String
        /// 开围栏后的语言提示（如 `swift`），无提示时为 nil。
        let languageHint: String?
    }

    private struct Fence {
        let marker: Character
        let count: Int
        /// 围栏后的剩余文本（去除首尾空白），结束围栏时为空。
        let trailing: String
    }

    private static func fencedBlocks(in text: String) -> [FencedBlock] {
        var blocks: [FencedBlock] = []
        let lines = enumerateLines(in: text)
        var index = 0

        while index < lines.count {
            let line = lines[index]
            guard let opening = fenceInfo(of: line.content) else {
                index += 1
                continue
            }

            var contentLines: [String] = []
            var closingIndex: Int?
            var cursor = index + 1
            while cursor < lines.count {
                let candidate = lines[cursor].content
                if let closing = fenceInfo(of: candidate),
                   closing.marker == opening.marker,
                   closing.count >= opening.count,
                   closing.trailing.isEmpty {
                    closingIndex = cursor
                    break
                }
                contentLines.append(String(trimLineEnding(candidate)))
                cursor += 1
            }

            let end = closingIndex.map { lines[$0].range.upperBound } ?? text.endIndex
            let content = contentLines.joined(separator: "\n") + (contentLines.isEmpty ? "" : "\n")
            let language = opening.trailing.isEmpty
                ? nil
                : String(opening.trailing.split(whereSeparator: \.isWhitespace).first ?? "")
            blocks.append(
                FencedBlock(
                    range: lines[index].range.lowerBound..<end,
                    content: content,
                    languageHint: language
                )
            )
            index = (closingIndex ?? lines.count - 1) + 1
        }

        return blocks
    }

    /// 按行枚举文本（含行尾换行符），空文本返回空数组。
    ///
    /// 注意：`\r\n` 在 Swift 中是一个 Character（grapheme cluster），必须按
    /// unicode scalar 切分换行，否则 CRLF 文本会被当作一行。
    private struct Line {
        let range: Range<String.Index>
        let content: Substring
    }

    private static func enumerateLines(in text: String) -> [Line] {
        guard !text.isEmpty else { return [] }
        let scalars = text.unicodeScalars
        var result: [Line] = []
        var start = scalars.startIndex
        while start < scalars.endIndex {
            let newline = scalars[start...].firstIndex(of: "\n" as Unicode.Scalar)
            let end = newline.map { scalars.index(after: $0) } ?? scalars.endIndex
            result.append(Line(range: start..<end, content: text[start..<end]))
            start = end
        }
        return result
    }

    /// 去掉行尾的换行符与回车符（不处理其他空白）。
    private static func trimLineEnding(_ line: Substring) -> Substring {
        let scalars = line.unicodeScalars
        var end = scalars.endIndex
        while end > scalars.startIndex {
            let previous = scalars.index(before: end)
            let scalar = scalars[previous]
            guard scalar == "\n" || scalar == "\r" else { break }
            end = previous
        }
        return line[..<end]
    }

    /// 解析行首围栏：0-3 个空格后出现连续 3 个以上的 `` ` `` 或 `~`。
    private static func fenceInfo(of line: Substring) -> Fence? {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " ", leadingSpaces < 3 {
            leadingSpaces += 1
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }

        let marker = line[index]
        guard marker == "`" || marker == "~" else { return nil }

        var count = 0
        while index < line.endIndex, line[index] == marker {
            count += 1
            index = line.index(after: index)
        }
        guard count >= 3 else { return nil }

        let trailing = line[index...].trimmingCharacters(in: .whitespacesAndNewlines)
        return Fence(marker: marker, count: count, trailing: trailing)
    }

    // MARK: - Parsing

    private static func parse(_ text: String) -> AttributedString {
        if let parsed = try? AttributedString(markdown: text, options: parsingOptions) {
            return parsed
        }
        return AttributedString(text)
    }
}
