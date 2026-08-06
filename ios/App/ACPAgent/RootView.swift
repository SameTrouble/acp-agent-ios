import SwiftUI
import ACPAgentCore

struct RootView: View {
    @EnvironmentObject var client: ACPClient

    var body: some View {
        Group {
            switch client.connectionState {
            case .disconnected:
                if client.loadPersistedCredentials() != nil {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Connecting...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ServerConfigView()
                }
            case .connecting:
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Connecting...")
                        .foregroundStyle(.secondary)
                }
            case .connected:
                SessionListView()
            case .failed(let message):
                ServerConfigView(errorMessage: message)
            }
        }
    }
}
