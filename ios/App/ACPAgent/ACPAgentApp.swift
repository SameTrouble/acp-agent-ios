import SwiftUI
import ACPAgentCore

@main
struct ACPAgentApp: App {
    @StateObject private var client = ACPClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .preferredColorScheme(.dark)
                .task {
                    if let creds = client.loadPersistedCredentials() {
                        _ = await client.connect(endpoint: creds.endpoint, token: creds.token)
                        if client.connectionState == .connected {
                            _ = try? await client.refreshSessions()
                        }
                    }
                }
        }
    }
}
