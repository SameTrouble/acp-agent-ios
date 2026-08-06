import SwiftUI
import ACPAgentCore

// MARK: - Diff card

/// One collapsible card per modified file (issue #9): collapsed it shows the
/// path and the +M/−K line counts; expanded it renders the unified diff with
/// red/green line tints, syntax highlighting, and horizontal scrolling for
/// long lines. Multiple files from one tool call each get their own card.
struct DiffCardView: View {
    let diff: FileDiff
    let status: ToolCallStatus
    /// Non-diff output text from the same tool call (e.g. "Edit applied
    /// successfully.") — rendered under the diff so nothing is lost when
    /// the generic tool card is replaced by diff cards.
    let outputText: [String]

    @State private var isExpanded = false

    private var language: SyntaxLanguage {
        SyntaxLanguage.detect(from: diff.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle diff for \(diff.path)")

            if isExpanded {
                Divider()
                if diff.lines.isEmpty {
                    Text("No changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                } else {
                    diffBody
                }
                if !outputText.isEmpty {
                    outputBlock
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(status.statusColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.statusColor)
                .frame(width: 24, height: 24)

            Text(diff.path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if diff.addedCount > 0 || diff.removedCount > 0 {
                HStack(spacing: 6) {
                    if diff.addedCount > 0 {
                        Text("+\(diff.addedCount)")
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    if diff.removedCount > 0 {
                        Text("−\(diff.removedCount)")
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.6))
                .clipShape(Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(12)
    }

    private var outputBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(outputText, id: \.self) { block in
                Text(block)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.quaternarySystemFill).opacity(0.5))
    }

    private var diffBody: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: Diff line rendering

    @ViewBuilder
    private func lineView(_ line: DiffLine) -> some View {
        if line.kind == .hunkHeader {
            Text(line.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .frame(minHeight: 20, alignment: .leading)
                .background(Color.blue.opacity(0.08))
                .fixedSize(horizontal: true, vertical: false)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(prefix(for: line.kind))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(prefixColor(for: line.kind))
                    .frame(width: 14, alignment: .center)
                highlightedText(line.text)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .frame(minHeight: 20, alignment: .leading)
            .background(lineBackground(for: line.kind))
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func prefix(for kind: DiffLineKind) -> String {
        switch kind {
        case .context: return " "
        case .addition: return "+"
        case .deletion: return "-"
        case .hunkHeader: return ""
        }
    }

    private func prefixColor(for kind: DiffLineKind) -> Color {
        switch kind {
        case .addition: return .green
        case .deletion: return .red
        case .context, .hunkHeader: return .secondary
        }
    }

    private func lineBackground(for kind: DiffLineKind) -> Color {
        switch kind {
        case .addition: return Color.green.opacity(0.14)
        case .deletion: return Color.red.opacity(0.14)
        case .context, .hunkHeader: return .clear
        }
    }

    /// Syntax-highlights the line content; the diff prefix stays unstyled.
    private func highlightedText(_ text: String) -> Text {
        var attr = AttributedString(text)
        let font = Font.system(.caption, design: .monospaced)
        attr.font = font
        guard language != .plain else { return Text(attr) }
        for token in SyntaxHighlighter.tokens(in: text, language: language) {
            guard let range = Range(token.range, in: attr) else { continue }
            attr[range].foregroundColor = color(for: token.kind)
        }
        return Text(attr)
    }

    private func color(for kind: SyntaxTokenKind) -> Color {
        switch kind {
        case .keyword: return .purple
        case .string: return .red
        case .comment: return .gray
        case .number: return .orange
        case .type: return .teal
        case .function: return .blue
        }
    }
}

// MARK: - Shared tool status styling

/// Accent color for a tool call's status glyph. Rendered by both the generic
/// tool card (`ToolCallCardView`) and the diff card; the icon itself lives in
/// Core as `ToolCallStatus.systemImage` alongside `ToolCallKind.systemImage`.
extension ToolCallStatus {
    var statusColor: Color {
        switch self {
        case .pending: return .orange
        case .running, .inProgress: return .blue
        case .completed: return .green
        case .error, .failed: return .red
        }
    }
}

// MARK: - Preview

#Preview {
    let oldText = """
    import Foundation

    func greet(name: String) -> String {
        return "Hi " + name
    }
    """
    let newText = """
    import Foundation

    func greet(name: String) -> String {
        // friendlier
        return "Hello, " + name
    }
    """
    let diff = FileDiff(path: "/proj/Greeter.swift", oldText: oldText, newText: newText)

    return ScrollView {
        VStack(spacing: 12) {
            DiffCardView(diff: diff, status: .completed, outputText: ["Edit applied successfully."])
            DiffCardView(
                diff: FileDiff(path: "/proj/config.json", oldText: #"{"port": 3000}"#, newText: #"{"port": 4000}"#),
                status: .completed,
                outputText: []
            )
        }
        .padding()
    }
}
