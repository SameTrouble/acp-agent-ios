import SwiftUI
import ACPAgentCore

struct SessionDetailView: View {
    @EnvironmentObject var client: ACPClient
    let sessionId: String

    @State private var scrollProxy: ScrollViewProxy?

    private var conversation: SessionConversation {
        client.conversation(for: sessionId)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if conversation.transcript.items.isEmpty && !conversation.isResuming {
                            emptyState
                        } else {
                            ForEach(conversation.transcript.items) { item in
                                switch item {
                                case .message(let message):
                                    MessageBubble(message: message)
                                case .toolCall(let card):
                                    if card.diffs.isEmpty {
                                        ToolCallCardView(call: card)
                                    } else {
                                        // Issue #9: file-editing calls render as one
                                        // collapsible diff card per modified file.
                                        ForEach(card.diffs, id: \.path) { diff in
                                            DiffCardView(diff: diff, status: card.status, outputText: card.content)
                                        }
                                    }
                                case .approval(let card):
                                    ApprovalCardView(card: card) { option in
                                        respondToApproval(card: card, option: option)
                                    }
                                }
                            }
                            if conversation.isSending || conversation.transcript.isGenerating {
                                TypingIndicator()
                                    .id("typing")
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onAppear { scrollProxy = proxy }
                .onChange(of: conversation.transcript.items.count) { _, _ in scrollToBottom() }
                .onChange(of: conversation.isSending) { _, _ in scrollToBottom() }
            }

            if let error = conversation.errorMessage {
                banner(error, icon: "exclamationmark.triangle.fill", tint: .orange)
            } else if conversation.recovery == .liveOnly {
                banner(
                    conversation.recoveryReason ?? "History unavailable — showing the live stream only.",
                    icon: "clock.badge.exclamationmark",
                    tint: .secondary
                )
            }

            PromptInputBar(
                sessionId: sessionId,
                availableCommands: conversation.availableCommands,
                configChipSummary: conversation.configChipSummary,
                canCancel: conversation.canCancel,
                onCancel: cancel
            )
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(sessionTitle)
        .task {
            await resumeIfConnected()
        }
        // Coming back from a dropped socket re-resumes from the last cursor, so
        // the screen catches up on whatever streamed while we were away.
        .onChange(of: client.connectionState) { _, newState in
            guard newState == .connected else { return }
            Task { await resumeIfConnected() }
        }
    }

    private func resumeIfConnected() async {
        guard client.connectionState == .connected else { return }
        _ = try? await client.resumeSession(id: sessionId)
    }

    private var sessionTitle: String {
        guard let session = client.sessions.first(where: { $0.id == sessionId }) else {
            return sessionId
        }
        return session.projectName
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No messages yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            if conversation.isResuming {
                Text("Loading conversation…")
            } else {
                Text("Send a message to start the conversation.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func banner(_ message: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.subheadline)
                .lineLimit(3)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08))
    }

    private func cancel() {
        Task {
            try? await client.cancelSession(id: sessionId)
        }
    }

    private func respondToApproval(card: PermissionCard, option: PermissionOption) {
        Task {
            // The store optimistically turns the card terminal before sending;
            // on failure it rolls back so the user can try again.
            try? await client.respondToPermission(sessionId: sessionId, requestId: card.requestId, option: option)
        }
    }

    private func scrollToBottom() {
        withAnimation(.easeOut(duration: 0.2)) {
            scrollProxy?.scrollTo(conversation.transcript.items.last?.id ?? "typing", anchor: .bottom)
        }
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: TranscriptMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user { Spacer(minLength: 24) }

            VStack(alignment: .leading, spacing: 4) {
                if message.role == .thought {
                    Label("Thinking", systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                markdownContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: message.role == .user ? .infinity : nil, alignment: message.role == .user ? .trailing : .leading)
            }
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)

            if message.role != .user { Spacer(minLength: 24) }
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user: return .accentColor
        case .assistant: return Color(.secondarySystemBackground)
        case .thought: return .purple.opacity(0.15)
        }
    }

    // MARK: - Markdown rendering

    @ViewBuilder
    private var markdownContent: some View {
        if message.text.isEmpty {
            // 保留既有的占位行为，气泡保持最小高度。
            Text(" ")
        } else {
            let segments = MarkdownContent.segments(from: message.text)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(segments.indices, id: \.self) { index in
                    segmentView(segments[index])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: MarkdownSegment) -> some View {
        switch segment {
        case .text(let attr):
            Text(styledInlineCode(in: attr))
                .textSelection(.enabled)
                .font(.body)
                .foregroundStyle(message.role == .user ? .white : .primary)
        case .codeBlock(let content, _):
            CodeBlockCard(content: content, isUser: message.role == .user)
        }
    }

    /// 行内 code（`inlinePresentationIntent` 含 `.code` 的 run）以等宽字体 +
    /// 浅背景区分，其余 run 保持原样。
    private func styledInlineCode(in attr: AttributedString) -> AttributedString {
        var result = attr
        for run in result.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else {
                continue
            }
            result[run.range].font = .system(.body, design: .monospaced)
            result[run.range].backgroundColor = inlineCodeBackground
        }
        return result
    }

    private var inlineCodeBackground: Color {
        message.role == .user ? .white.opacity(0.15) : .primary.opacity(0.08)
    }
}

// MARK: - Code block card

private struct CodeBlockCard: View {
    let content: String
    let isUser: Bool

    var body: some View {
        Text(content)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(isUser ? .white : .primary)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isUser ? Color.white.opacity(0.15) : Color(.quaternarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Tool call card

private struct ToolCallCardView: View {
    let call: ToolCallCard

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: call.kind.systemImage)
                .foregroundStyle(call.status.statusColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(call.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    statusBadge
                }

                if !call.locations.isEmpty {
                    ForEach(call.locations, id: \.self) { path in
                        Text(path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if !call.content.isEmpty {
                    DisclosureGroup {
                        Text(call.content.joined())
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Output", systemImage: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .disclosureGroupStyle(.automatic)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(call.status.statusColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            if call.status == .running {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: call.status.systemImage)
                    .foregroundStyle(call.status.statusColor)
            }
            Text(call.status.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Approval card

/// The structured permission card: one button per wire-provided option, so the
/// UI faithfully renders the agent's choices (ADR-005: allow once / always /
/// reject). Once the user answers, the card turns terminal and the buttons are
/// replaced by the outcome — it can never be answered twice.
private struct ApprovalCardView: View {
    let card: PermissionCard
    let onSelect: (PermissionOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key")
                    .foregroundStyle(accentColor)
                Text("Permission Request")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if card.state.isTerminal {
                    terminalBadge
                }
            }

            Text(card.toolCall.title ?? card.toolCall.toolCallId)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)

            if !card.toolCall.locations.isEmpty {
                ForEach(card.toolCall.locations, id: \.self) { path in
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !card.toolCall.summaryLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(card.toolCall.summaryLines, id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if !card.toolCall.content.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(card.toolCall.content, id: \.self) { block in
                        Text(block)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if card.state == .pending {
                optionsRow
            } else {
                outcomeLine
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var accentColor: Color {
        if isRejected { return .red }
        return card.state.isTerminal ? .green : .orange
    }

    private var isRejected: Bool {
        card.state == .rejected
    }

    /// Buttons are rendered from the wire options, not hardcoded (ADR-005).
    private var optionsRow: some View {
        HStack(spacing: 8) {
            ForEach(card.options) { option in
                Button {
                    onSelect(option)
                } label: {
                    Text(option.name)
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(option.isAllow ? .accentColor : .red)
                .accessibilityLabel(option.name)
            }
        }
    }

    private var terminalBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: isRejected ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(accentColor)
            Text(terminalTitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var outcomeLine: some View {
        HStack(spacing: 6) {
            Image(systemName: isRejected ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(accentColor)
            Text(outcomeDescription)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(accentColor)
        }
    }

    private var terminalTitle: String {
        isRejected ? "Rejected" : "Approved"
    }

    private var outcomeDescription: String {
        switch card.state {
        case .pending:
            return ""
        case .approved(let optionId):
            let name = card.options.first { $0.optionId == optionId }?.name ?? "Approved"
            return "Approved — \(name)"
        case .rejected:
            return "Rejected"
        }
    }
}

// MARK: - Typing indicator

private struct TypingIndicator: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .animation(
                        .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2),
                        value: isAnimating
                    )
                    .scaleEffect(isAnimating ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { isAnimating = true }
    }

    @State private var isAnimating = false
}

// MARK: - Input bar

// The session input area (text + @-reference chips + /-command panel) lives in
// `PromptInputBar.swift`.

#Preview {
    NavigationStack {
        SessionDetailView(sessionId: "sess_abc123")
            .environmentObject(ACPClient())
    }
}
