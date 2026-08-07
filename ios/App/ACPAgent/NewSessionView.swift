import SwiftUI
import ACPAgentCore

/// New-session sheet (issue #12): a "recent projects" shortcut list derived
/// from the session list, plus a server directory browser fed by the
/// companion's `dir.browse`. Selecting a directory — from either — creates a
/// session rooted there via `session/new` and hands the new session id back
/// through `onCreated`.
struct NewSessionView: View {
    @EnvironmentObject var client: ACPClient
    @Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void

    @State private var listing: DirectoryListing?
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var recentProjects: [ProjectGroup] {
        client.sessions.groupedByProject()
    }

    var body: some View {
        NavigationStack {
            List {
                if !recentProjects.isEmpty {
                    recentProjectsSection
                }
                browserSection
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        createSession(cwd: listing?.path ?? "/")
                    } label: {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("Use This Folder")
                        }
                    }
                    .disabled(listing == nil || isCreating)
                }
            }
            .task { await browse(nil) }
        }
    }

    // MARK: - Recent projects

    private var recentProjectsSection: some View {
        Section("Recent Projects") {
            ForEach(recentProjects) { group in
                Button {
                    createSession(cwd: group.cwd)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.body)
                            Text(group.cwd)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if isCreating {
                            ProgressView()
                        } else {
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                    }
                }
                .disabled(isCreating)
            }
        }
    }

    // MARK: - Directory browser

    private var browserSection: some View {
        Section {
            if isLoading && listing == nil {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let listing {
                if let parent = listing.parent {
                    Button {
                        Task { await browse(parent) }
                    } label: {
                        Label("..", systemImage: "arrowshape.turn.up.left")
                    }
                    .disabled(isLoading || isCreating)
                }
                ForEach(listing.entries, id: \.path) { entry in
                    Button {
                        Task { await browse(entry.path) }
                    } label: {
                        Label(entry.name, systemImage: "folder")
                    }
                    .disabled(isLoading || isCreating)
                }
                if listing.entries.isEmpty {
                    Text("Empty folder")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            if let listing {
                Text(listing.path)
                    .lineLimit(2)
            } else {
                Text("Browse")
            }
        } footer: {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Actions

    private func browse(_ path: String?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            listing = try await client.browseDirectory(path: path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createSession(cwd: String) {
        guard !isCreating else { return }
        isCreating = true
        errorMessage = nil
        Task {
            do {
                let sessionId = try await client.createSession(cwd: cwd)
                dismiss()
                onCreated(sessionId)
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
