import SwiftUI
import ACPAgentCore

/// Chip next to the prompt field showing the current model / config summary.
/// Tapping opens the generic config bottom sheet (issue #11).
struct SessionConfigChip: View {
    let summary: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption2)
                Text(summary)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 140, alignment: .leading)
            .background(Capsule().fill(.quaternary.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Session configuration: \(summary)")
    }
}

/// Bottom sheet listing every select-type config option in agent priority
/// order. Selection calls through `ACPClient.setConfigOption` — no model-
/// specific branches (issue #11).
struct SessionConfigSheet: View {
    @EnvironmentObject var client: ACPClient
    @Environment(\.dismiss) private var dismiss

    let sessionId: String

    @State private var isSaving = false
    @State private var errorMessage: String?

    private var options: [SessionConfigOption] {
        client.conversation(for: sessionId).selectableConfigOptions
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(options, id: \.id) { option in
                    Section {
                        ForEach(option.options ?? [], id: \.value) { value in
                            Button {
                                select(option: option, value: value.value)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(value.name)
                                            .foregroundStyle(.primary)
                                        if let description = value.description, !description.isEmpty {
                                            Text(description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if option.currentValue.stringValue == value.value {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isSaving)
                            .accessibilityLabel(value.name)
                            .accessibilityAddTraits(
                                option.currentValue.stringValue == value.value ? .isSelected : []
                            )
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.name)
                            if let description = option.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textCase(nil)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isSaving)
                }
            }
        }
    }

    private func select(option: SessionConfigOption, value: String) {
        guard option.currentValue.stringValue != value else {
            dismiss()
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                _ = try await client.setConfigOption(sessionId: sessionId, configId: option.id, value: value)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
