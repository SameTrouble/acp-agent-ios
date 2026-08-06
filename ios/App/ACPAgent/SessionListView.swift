import SwiftUI
import ACPAgentCore

struct SessionListView: View {
    @EnvironmentObject var client: ACPClient
    @State private var isRefreshing = false
    @State private var refreshError: String?

    var body: some View {
        NavigationStack {
            Group {
                if client.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No Sessions", systemImage: "tray")
                    } description: {
                        Text("Start a new session from your agent to see it here.")
                    } actions: {
                        Button("Refresh") {
                            Task { await refresh() }
                        }
                    }
                } else {
                    List {
                        ForEach(client.sessions.groupedByProject()) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    SessionRow(session: session)
                                }
                            } header: {
                                HStack {
                                    Text(group.name)
                                        .font(.headline)
                                    if group.pendingCount > 0 {
                                        Badge(count: group.pendingCount)
                                    }
                                    Spacer()
                                }
                                .textCase(nil)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refresh") {
                            Task { await refresh() }
                        }
                        Divider()
                        Button("Sign Out", role: .destructive) {
                            Task { await client.signOut() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                if isRefreshing {
                    ToolbarItem(placement: .topBarLeading) {
                        ProgressView()
                    }
                }
            }
            .refreshable {
                await refresh()
            }
            .overlay(alignment: .bottom) {
                if let error = refreshError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.subheadline)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        Task {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            withAnimation { refreshError = nil }
                        }
                    }
                }
            }
        }
    }

    private func refresh() async {
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }

        do {
            _ = try await client.refreshSessions()
        } catch {
            refreshError = error.localizedDescription
        }
    }
}

private struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 12) {
            StatusIndicator(status: session.status)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.id)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)

                Text(session.status.localizedTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if session.hasPendingApproval {
                Badge(count: 1)
            }

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

private struct StatusIndicator: View {
    let status: SessionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch status {
        case .active: return .green
        case .ended: return .gray
        case .interrupted: return .orange
        }
    }
}

private struct Badge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.red)
            .clipShape(Capsule())
    }
}

extension SessionStatus {
    var localizedTitle: String {
        switch self {
        case .active: return "Active"
        case .ended: return "Ended"
        case .interrupted: return "Interrupted"
        }
    }
}
