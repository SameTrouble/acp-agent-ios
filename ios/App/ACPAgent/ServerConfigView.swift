import SwiftUI
import ACPAgentCore

struct ServerConfigView: View {
    @EnvironmentObject var client: ACPClient

    let errorMessage: String?

    @State private var endpointText: String = ""
    @State private var tokenText: String = ""
    @State private var isConnecting = false
    @State private var localError: String?
    @State private var showToken = false

    init(errorMessage: String? = nil) {
        self.errorMessage = errorMessage
    }

    private var endpointIsValid: Bool {
        ServerEndpoint.parse(endpointText) != nil
    }

    private var canConnect: Bool {
        endpointIsValid && !tokenText.isEmpty && !isConnecting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ws://localhost:8787", text: $endpointText, prompt: Text("Server endpoint"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: endpointText) { _, _ in localError = nil }
                } header: {
                    Text("Server")
                } footer: {
                    if !endpointText.isEmpty && !endpointIsValid {
                        Text("Invalid endpoint")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    HStack {
                        if showToken {
                            TextField("Access token", text: $tokenText, prompt: Text("Access token"))
                        } else {
                            SecureField("Access token", text: $tokenText, prompt: Text("Access token"))
                        }
                        Button {
                            showToken.toggle()
                        } label: {
                            Image(systemName: showToken ? "eye.slash.fill" : "eye.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: tokenText) { _, _ in localError = nil }
                } header: {
                    Text("Token")
                } footer: {
                    Text("Token is stored securely in Keychain and never leaves the device in plaintext.")
                }

                if let displayError = localError ?? errorMessage {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(displayError)
                        }
                    }
                }

                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Connect")
                                    .bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canConnect)
                    .listRowBackground(canConnect ? Color.accentColor : Color.gray.opacity(0.3))
                    .foregroundStyle(.white)
                }
            }
            .navigationTitle("ACP Agent")
            .onAppear {
                if let endpoint = client.loadPersistedCredentials()?.endpoint.displayString {
                    endpointText = endpoint
                }
            }
        }
    }

    private func connect() async {
        guard let endpoint = ServerEndpoint.parse(endpointText) else {
            localError = "Invalid endpoint"
            return
        }
        guard !tokenText.isEmpty else {
            localError = "Token is required"
            return
        }

        isConnecting = true
        localError = nil
        defer { isConnecting = false }

        _ = await client.connect(endpoint: endpoint, token: tokenText)

        if case .connected = client.connectionState {
            _ = try? await client.refreshSessions()
        }
    }
}
