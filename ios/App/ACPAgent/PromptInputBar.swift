import SwiftUI
import ACPAgentCore

/// A selected file reference, shown as a removable chip above the text field.
/// Sent as a `file_ref` prompt block and expanded by the companion (issue #8).
struct FileReference: Identifiable, Equatable {
    let id = UUID()
    let path: String
}

/// The session input area: text field + removable `@`-reference chips, with a
/// live suggestion panel — `/` lists the agent-advertised commands
/// (`available_commands_update`, which already excludes client-side actions
/// like new-session or cancel), `@` fuzzy-searches the session's working
/// directory via `files.search`. Sending packs the text plus one `file_ref`
/// block per chip; the companion expands references into content the agent
/// reads. Trigger semantics live in Core's `PromptTrigger` (ADR-001).
@MainActor
struct PromptInputBar: View {
    @EnvironmentObject var client: ACPClient

    let sessionId: String
    let availableCommands: [AvailableCommand]
    let canCancel: Bool
    let onCancel: () -> Void

    @State private var text = ""
    @State private var references: [FileReference] = []
    @State private var trigger: PromptTrigger?
    @State private var fileResults: [FileSearchResult] = []
    @State private var fileSearchFailed = false
    @State private var fileSearchTask: Task<Void, Never>?
    /// Set after picking a command, so the placeholder invites arguments.
    @State private var argumentPlaceholder: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let trigger {
                suggestionPanel(for: trigger)
            }
            chipsRow
            inputRow
        }
        .onChange(of: text) { _, newValue in
            updateTrigger(for: newValue)
        }
    }

    private var canSend: Bool {
        guard !canCancel else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !references.isEmpty
    }

    // MARK: - Chips

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(references) { reference in
                    chip(reference)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func chip(_ reference: FileReference) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "paperclip")
                .font(.caption2)
            Text(reference.path)
                .font(.caption)
                .lineLimit(1)
            Button {
                removeReference(reference)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove reference \(reference.path)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.quaternary.opacity(0.5))
                )
                .disabled(canCancel)

            if canCancel {
                Button(action: onCancel) {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.red)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
            } else {
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(canSend ? Color.accentColor : Color.gray.opacity(0.4))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .onSubmit(sendIfPossible)
    }

    private func sendIfPossible() {
        if canSend { send() }
    }

    private func send() {
        var blocks: [PromptBlock] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(.text(trimmed))
        }
        blocks.append(contentsOf: references.map { .fileRef(path: $0.path) })
        guard !blocks.isEmpty else { return }

        text = ""
        references = []
        trigger = nil
        fileResults = []
        fileSearchFailed = false
        argumentPlaceholder = nil
        fileSearchTask?.cancel()

        Task {
            _ = try? await client.sendPrompt(sessionId: sessionId, prompt: blocks)
        }
    }

    // MARK: - Suggestion trigger

    /// `/` at the start of the input opens the command panel (hidden once the
    /// query contains a space — i.e. after a command was picked and arguments
    /// follow). `@` opens the file panel with a debounced companion search.
    /// The parse rules live in Core's `PromptTrigger` (ADR-001).
    private func updateTrigger(for newValue: String) {
        if let newTrigger = PromptTrigger.parse(text: newValue) {
            trigger = newTrigger
            if case .commands = newTrigger {
                fileSearchTask?.cancel()
            } else if case .files(let query) = newTrigger {
                argumentPlaceholder = nil
                scheduleFileSearch(query: query)
            }
        } else {
            fileSearchTask?.cancel()
            trigger = nil
            argumentPlaceholder = nil
        }
    }

    // MARK: - Suggestion panels

    @ViewBuilder
    private func suggestionPanel(for trigger: PromptTrigger) -> some View {
        switch trigger {
        case .commands(let query):
            commandPanel(query: query)
        case .files:
            filePanel
        }
    }

    private func commandPanel(query: String) -> some View {
        let matches = PromptTrigger.commands(query: query).filteredCommands(from: availableCommands)
        return panelContainer {
            if availableCommands.isEmpty {
                label("No commands available")
            } else if matches.isEmpty {
                label("No matching commands")
            } else {
                ForEach(matches, id: \.name) { command in
                    suggestionRow(
                        icon: "chevron.right.square",
                        title: "/\(command.name)",
                        subtitle: command.description
                    ) {
                        selectCommand(command)
                    }
                    Divider()
                }
            }
        }
    }

    private var filePanel: some View {
        panelContainer {
            if fileSearchFailed {
                label("Search unavailable — check the connection")
            } else if fileResults.isEmpty {
                label("No files found")
            } else {
                ForEach(fileResults, id: \.path) { result in
                    suggestionRow(icon: "doc.text", title: result.path) {
                        selectFile(result)
                    }
                    Divider()
                }
            }
        }
    }

    private func suggestionRow(
        icon: String,
        title: String,
        subtitle: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private func panelContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .frame(maxHeight: 240)
        .scrollIndicators(.hidden)
    }

    private func filteredCommands(for query: String) -> [AvailableCommand] {
        guard !query.isEmpty else { return availableCommands }
        return availableCommands.filter { command in
            command.name.localizedCaseInsensitiveContains(query)
                || (command.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    // MARK: - Selection

    /// Picks a command: the input becomes `/name ` so the user can type
    /// arguments; the panel closes (the trailing space trips the
    /// `hasArgumentSeparator` rule) and the prompt is sent as plain text,
    /// which the agent executes as the command (live-verified, issue #8).
    private func selectCommand(_ command: AvailableCommand) {
        text = "/\(command.name) "
        trigger = nil
        argumentPlaceholder = "Arguments for /\(command.name)…"
        fileSearchTask?.cancel()
    }

    private func selectFile(_ result: FileSearchResult) {
        references.append(FileReference(path: result.path))
        text = ""
        trigger = nil
        fileSearchFailed = false
        fileSearchTask?.cancel()
        isFocused = true
    }

    private func removeReference(_ reference: FileReference) {
        references.removeAll { $0.id == reference.id }
    }

    // MARK: - File search

    private func scheduleFileSearch(query: String) {
        fileSearchTask?.cancel()
        fileSearchTask = Task {
            // Debounce: only search once the user pauses typing.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            do {
                let results = try await client.searchFiles(sessionId: sessionId, query: query)
                guard !Task.isCancelled else { return }
                fileResults = results
                fileSearchFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                fileResults = []
                fileSearchFailed = true
            }
        }
    }

    private var placeholder: String {
        argumentPlaceholder ?? "Message the agent…"
    }
}

#Preview {
    PromptInputBar(
        sessionId: "sess_abc123",
        availableCommands: [
            AvailableCommand(name: "code-review", description: "Review the changes since a fixed point."),
            AvailableCommand(name: "tdd", description: "Test-driven development."),
        ],
        canCancel: false,
        onCancel: {}
    )
    .environmentObject(ACPClient())
}
