import Foundation

// MARK: - Diff line model

/// One line of a rendered unified diff. `text` carries the content without
/// the `+`/`-`/` ` prefix — the UI draws the prefix glyph from `kind`.
public enum DiffLineKind: String, Codable, Equatable, Sendable {
    case context
    case addition
    case deletion
    case hunkHeader
}

public struct DiffLine: Codable, Equatable, Sendable {
    public let kind: DiffLineKind
    public let text: String

    public init(kind: DiffLineKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// The render-ready output of a unified-diff computation.
public struct DiffRender: Equatable, Sendable {
    public let lines: [DiffLine]
    public let addedCount: Int
    public let removedCount: Int

    public init(lines: [DiffLine], addedCount: Int, removedCount: Int) {
        self.lines = lines
        self.addedCount = addedCount
        self.removedCount = removedCount
    }
}

/// Structural decode of the wire's `{type: "diff", path, oldText, newText}`
/// content block (live-verified against opencode 1.18.13, issue #9). The
/// unified diff itself is computed client-side from the old/new texts — the
/// agent only sends the two versions, not a pre-formatted patch.
public struct FileDiff: Codable, Equatable, Sendable {
    public let path: String
    public let oldText: String?
    public let newText: String
    /// Unified-diff lines with hunk headers, ready for rendering.
    public let lines: [DiffLine]
    public let addedCount: Int
    public let removedCount: Int

    public init(path: String, oldText: String?, newText: String, contextLines: Int = 3) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
        let render = UnifiedDiff.render(
            old: Self.lines(of: oldText ?? ""),
            new: Self.lines(of: newText),
            contextLines: contextLines
        )
        self.lines = render.lines
        self.addedCount = render.addedCount
        self.removedCount = render.removedCount
    }

    enum CodingKeys: String, CodingKey {
        case path, oldText, newText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        oldText = try container.decodeIfPresent(String.self, forKey: .oldText)
        newText = try container.decodeIfPresent(String.self, forKey: .newText) ?? ""
        let render = UnifiedDiff.render(
            old: Self.lines(of: oldText ?? ""),
            new: Self.lines(of: newText),
            contextLines: 3
        )
        lines = render.lines
        addedCount = render.addedCount
        removedCount = render.removedCount
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(oldText, forKey: .oldText)
        try container.encode(newText, forKey: .newText)
    }

    /// Decodes one wire content block of type `diff` —
    /// `{type: "diff", path, oldText?, newText}` (live-verified on opencode
    /// 1.18.13). Returns nil for any other block type. Shared by the
    /// `session/update` tool-call path and the permission-request preview
    /// so both surfaces decode the same wire shape the same way (ADR-003).
    public static func decode(from block: AnyCodable) -> FileDiff? {
        guard let dict = block.value.base as? [String: AnyCodable],
              (dict["type"]?.value.base as? String) == "diff" else { return nil }
        let path = (dict["path"]?.value.base as? String) ?? ""
        let oldText = dict["oldText"]?.value.base as? String
        let newText = (dict["newText"]?.value.base as? String) ?? ""
        return FileDiff(path: path, oldText: oldText, newText: newText)
    }

    static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

// MARK: - Unified diff engine

/// Myers O(ND) line diff rendered into unified-diff hunks with context,
/// using the linear-space divide-and-conquer variant (same algorithm family
/// as git): forward/backward searches meet at a middle snake, then each half
/// recurses, so memory stays O(N+M) and no edit-step budget is needed — the
/// diff stays exact even for heavily-scattered edits. Only a total-size guard
/// remains, for inputs no real file-edit diff hits.
public enum UnifiedDiff {
    /// Beyond this combined line count the middle is rendered as a
    /// whole-file replacement (defensive; a 10k-line scattered edit is not a
    /// realistic agent workload).
    private static let maxTotalLines = 20_000

    private enum Edit {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    /// A rectangular sub-grid of the edit graph: `a[left..<right]` vs
    /// `b[top..<bottom]`.
    private struct Box {
        let left: Int
        let top: Int
        let right: Int
        let bottom: Int

        var width: Int { right - left }
        var height: Int { bottom - top }
        var size: Int { width + height }
        var delta: Int { width - height }
    }

    /// The segment where the forward and backward searches meet. In forward
    /// traversal order it is one move plus a diagonal run; `forward` says
    /// whether the move comes first (found by the forward search) or last
    /// (found by the backward search). `start` is the segment's first vertex,
    /// `end` its last.
    private struct Snake {
        let startX: Int
        let startY: Int
        let endX: Int
        let endY: Int
        let forward: Bool
    }

    private struct PositionedEdit {
        let edit: Edit
        let oldIndex: Int
        let newIndex: Int
    }

    public static func render(old: String, new: String, contextLines: Int = 3) -> DiffRender {
        render(old: FileDiff.lines(of: old), new: FileDiff.lines(of: new), contextLines: contextLines)
    }

    public static func render(old oldLines: [String], new newLines: [String], contextLines: Int = 3) -> DiffRender {
        let edits = myers(oldLines, newLines)
        var added = 0
        var removed = 0

        // First pass: group change runs into blocks and tally the counts.
        var blocks: [(startOld: Int, endOld: Int, startNew: Int, endNew: Int)] = []
        var current: (startOld: Int, endOld: Int, startNew: Int, endNew: Int)?
        var oldIndex = 0
        var newIndex = 0
        for edit in edits {
            switch edit {
            case .equal:
                oldIndex += 1
                newIndex += 1
                if current != nil {
                    blocks.append(current!)
                    current = nil
                }
            case .delete:
                if current == nil {
                    current = (oldIndex, oldIndex + 1, newIndex, newIndex)
                } else {
                    current!.endOld = oldIndex + 1
                }
                oldIndex += 1
                removed += 1
            case .insert:
                if current == nil {
                    current = (oldIndex, oldIndex, newIndex, newIndex + 1)
                } else {
                    current!.endNew = newIndex + 1
                }
                newIndex += 1
                added += 1
            }
        }
        if let current { blocks.append(current) }
        guard !blocks.isEmpty else {
            return DiffRender(lines: [], addedCount: 0, removedCount: 0)
        }

        // Merge blocks whose separating context fits inside one hunk.
        var merged: [(startOld: Int, endOld: Int, startNew: Int, endNew: Int)] = []
        for block in blocks {
            if let last = merged.last,
               block.startOld - last.endOld <= 2 * contextLines,
               block.startNew - last.endNew <= 2 * contextLines {
                merged[merged.count - 1] = (last.startOld, block.endOld, last.startNew, block.endNew)
            } else {
                merged.append(block)
            }
        }

        // Positioned edits so hunks can slice exactly the lines they cover.
        var positioned: [PositionedEdit] = []
        positioned.reserveCapacity(edits.count)
        oldIndex = 0
        newIndex = 0
        for edit in edits {
            positioned.append(PositionedEdit(edit: edit, oldIndex: oldIndex, newIndex: newIndex))
            switch edit {
            case .equal:
                oldIndex += 1
                newIndex += 1
            case .delete:
                oldIndex += 1
            case .insert:
                newIndex += 1
            }
        }

        var lines: [DiffLine] = []
        lines.reserveCapacity(positioned.count + merged.count)
        for block in merged {
            let ctxStartOld = max(0, block.startOld - contextLines)
            let ctxStartNew = max(0, block.startNew - contextLines)
            let hunkEndOld = min(block.endOld + contextLines, oldLines.count)
            let hunkEndNew = min(block.endNew + contextLines, newLines.count)

            lines.append(DiffLine(kind: .hunkHeader, text: hunkHeader(
                startOld: ctxStartOld,
                countOld: hunkEndOld - ctxStartOld,
                startNew: ctxStartNew,
                countNew: hunkEndNew - ctxStartNew
            )))

            for item in positioned {
                switch item.edit {
                case .equal(let text):
                    if item.oldIndex >= ctxStartOld,
                       item.oldIndex < hunkEndOld,
                       item.newIndex >= ctxStartNew,
                       item.newIndex < hunkEndNew {
                        lines.append(DiffLine(kind: .context, text: text))
                    }
                case .delete(let text):
                    if item.oldIndex >= block.startOld, item.oldIndex < block.endOld {
                        lines.append(DiffLine(kind: .deletion, text: text))
                    }
                case .insert(let text):
                    if item.newIndex >= block.startNew, item.newIndex < block.endNew {
                        lines.append(DiffLine(kind: .addition, text: text))
                    }
                }
            }
        }
        return DiffRender(lines: lines, addedCount: added, removedCount: removed)
    }

    /// `@@ -start,count +start,count @@`; a count of 1 is omitted and an
    /// empty side is written `0,0`, matching git's unified-diff convention.
    private static func hunkHeader(startOld: Int, countOld: Int, startNew: Int, countNew: Int) -> String {
        var text = "@@ -"
        if countOld == 0 {
            text += "0,0"
        } else {
            text += "\(startOld + 1)"
            if countOld != 1 { text += ",\(countOld)" }
        }
        text += " +"
        if countNew == 0 {
            text += "0,0"
        } else {
            text += "\(startNew + 1)"
            if countNew != 1 { text += ",\(countNew)" }
        }
        return text + " @@"
    }

    // MARK: Myers diff (linear space, divide and conquer)

    private static func myers(_ a: [String], _ b: [String]) -> [Edit] {
        if a.isEmpty { return b.map(Edit.insert) }
        if b.isEmpty { return a.map(Edit.delete) }

        // Trim common prefix and suffix — most agent edits leave most of the
        // file untouched, and trimming shrinks the recursive sub-grids.
        var start = 0
        while start < min(a.count, b.count), a[start] == b[start] { start += 1 }
        var endA = a.count
        var endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1
            endB -= 1
        }

        var result: [Edit] = []
        result.reserveCapacity(a.count + b.count)
        for i in 0..<start { result.append(.equal(a[i])) }
        let midA = Array(a[start..<endA])
        let midB = Array(b[start..<endB])
        if midA.count + midB.count > maxTotalLines {
            result.append(contentsOf: midA.map(Edit.delete) + midB.map(Edit.insert))
        } else {
            let box = Box(left: 0, top: 0, right: midA.count, bottom: midB.count)
            result.append(contentsOf: myersLinear(midA, midB, box: box))
        }
        for i in endA..<a.count { result.append(.equal(a[i])) }
        return result
    }

    private static func myersLinear(_ a: [String], _ b: [String], box: Box) -> [Edit] {
        guard box.size > 0 else { return [] }
        guard let snake = midpoint(box, a, b) else {
            // Defensive: Myers' theorem guarantees the searches meet for any
            // non-empty box; this keeps the renderer honest if that ever broke.
            var replace: [Edit] = []
            replace.reserveCapacity(box.size)
            for i in box.left..<box.right { replace.append(.delete(a[i])) }
            for j in box.top..<box.bottom { replace.append(.insert(b[j])) }
            return replace
        }

        let head = myersLinear(a, b, box: Box(
            left: box.left, top: box.top, right: snake.startX, bottom: snake.startY
        ))
        var result = head
        // The middle snake is one move (delete or insert) plus a diagonal run
        // of equal lines. A forward-found snake leads with the move; a
        // backward-found snake trails with it. Emit both explicitly — neither
        // half of the recursion covers them.
        let dx = snake.endX - snake.startX
        let dy = snake.endY - snake.startY
        if dx == dy {
            // Pure diagonal (d == 0 meeting): every step is an equal line.
            var x = snake.startX
            while x < snake.endX {
                result.append(.equal(a[x]))
                x += 1
            }
        } else if dx == dy + 1 {
            // The move deletes one old line: it leads the snake when found
            // forward and trails it when found backward.
            if snake.forward {
                result.append(.delete(a[snake.startX]))
                var x = snake.startX + 1
                while x < snake.endX {
                    result.append(.equal(a[x]))
                    x += 1
                }
            } else {
                var x = snake.startX
                while x < snake.endX - 1 {
                    result.append(.equal(a[x]))
                    x += 1
                }
                result.append(.delete(a[snake.endX - 1]))
            }
        } else {
            // dy == dx + 1: the move inserts one new line.
            if snake.forward {
                result.append(.insert(b[snake.startY]))
            } else {
                result.append(.insert(b[snake.endY - 1]))
            }
            var x = snake.startX
            while x < snake.endX {
                result.append(.equal(a[x]))
                x += 1
            }
        }
        result.append(contentsOf: myersLinear(a, b, box: Box(
            left: snake.endX, top: snake.endY, right: box.right, bottom: box.bottom
        )))
        return result
    }

    /// Runs the forward and backward searches alternately until they overlap
    /// on a diagonal; the overlap is the middle snake.
    private static func midpoint(_ box: Box, _ a: [String], _ b: [String]) -> Snake? {
        let max = box.size / 2 + (box.size % 2 == 1 ? 1 : 0)
        let offset = max + 1
        var vf = [Int](repeating: 0, count: 2 * max + 3)
        var vb = [Int](repeating: 0, count: 2 * max + 3)
        // k=+1 / c=+1 sentinels, mirroring the original V[1] = 0 convention.
        vf[1 + offset] = box.left
        vb[1 + offset] = box.bottom
        for d in 0...max {
            if let snake = forward(box, &vf, vb, d, offset, a, b) { return snake }
            if let snake = backward(box, vf, &vb, d, offset, a, b) { return snake }
        }
        return nil
    }

    private static func forward(
        _ box: Box, _ vf: inout [Int], _ vb: [Int], _ d: Int, _ offset: Int,
        _ a: [String], _ b: [String]
    ) -> Snake? {
        for k in stride(from: d, through: -d, by: -2) {
            let c = k - box.delta
            var x = 0
            var px = 0
            if k == -d || (k != d && vf[k - 1 + offset] < vf[k + 1 + offset]) {
                x = vf[k + 1 + offset]
                px = x
            } else {
                px = vf[k - 1 + offset]
                x = px + 1
            }
            var y = box.top + (x - box.left) - k
            let py = d == 0 || x != px ? y : y - 1
            while x < box.right, y < box.bottom, a[x] == b[y] {
                x += 1
                y += 1
            }
            vf[k + offset] = x
            if box.delta % 2 != 0, c >= -(d - 1), c <= d - 1, y >= vb[c + offset] {
                return Snake(startX: px, startY: py, endX: x, endY: y, forward: true)
            }
        }
        return nil
    }

    private static func backward(
        _ box: Box, _ vf: [Int], _ vb: inout [Int], _ d: Int, _ offset: Int,
        _ a: [String], _ b: [String]
    ) -> Snake? {
        for c in stride(from: d, through: -d, by: -2) {
            let k = c + box.delta
            var y = 0
            var py = 0
            if c == -d || (c != d && vb[c - 1 + offset] > vb[c + 1 + offset]) {
                y = vb[c + 1 + offset]
                py = y
            } else {
                py = vb[c - 1 + offset]
                y = py - 1
            }
            var x = box.left + (y - box.top) + k
            let px = d == 0 || y != py ? x : x + 1
            while x > box.left, y > box.top, a[x - 1] == b[y - 1] {
                x -= 1
                y -= 1
            }
            vb[c + offset] = y
            if box.delta % 2 == 0, k >= -d, k <= d, x <= vf[k + offset] {
                return Snake(startX: x, startY: y, endX: px, endY: py, forward: false)
            }
        }
        return nil
    }
}
