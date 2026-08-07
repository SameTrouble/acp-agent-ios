import Foundation

/// Owns all per-session conversation state — the `conversations` map — and the
/// conversation actions (resume, send, cancel, permission approve/reject).
///
/// `ACPClient` delegates to it and remains the only view-facing seam
/// (ADR-001/ADR-004); internal to the module so views cannot reach it.
@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var conversations: [String: SessionConversation] = [:]

    private let rpc: JsonRpcClient
    private let isConnected: @MainActor () -> Bool

    /// - Parameter isConnected: consulted by the conversation actions to enforce
    ///   the `ConnectionError.notConnected` guard. Provided by `ACPClient`,
    ///   which owns connection lifecycle.
    init(rpc: JsonRpcClient, isConnected: @escaping @MainActor () -> Bool) {
        self.rpc = rpc
        self.isConnected = isConnected
    }

    /// Read-only access to a session's conversation state. A new, empty one is
    /// vended on first access so callers can observe state before any activity.
    func conversation(for sessionId: String) -> SessionConversation {
        conversations[sessionId] ?? SessionConversation()
    }

    // MARK: - Conversation actions

    /// Resumes a session, replaying any buffered events the client has missed
    /// since its last known cursor. The resulting transcript and cursor are
    /// stored in `conversations[sessionId]`.
    @discardableResult
    func resumeSession(id sessionId: String) async throws -> SessionResumeResponse {
        guard isConnected() else {
            throw ConnectionError.notConnected
        }

        var params: [String: AnyCodable] = ["sessionId": AnyCodable(sessionId)]
        if let cursor = conversation(for: sessionId).cursor {
            params["cursor"] = AnyCodable(cursor)
        }

        mutateConversation(sessionId) { $0.isResuming = true }
        defer { mutateConversation(sessionId) { $0.isResuming = false } }

        let result = try await rpc.request("session.resume", params: params)
        let response = try result.decode(SessionResumeResponse.self)

        mutateConversation(sessionId) { conv in
            conv.recovery = response.recovery
            conv.recoveryReason = response.reason
            conv.applySessionConfig(configOptions: response.configOptions, modes: response.modes)

            for event in response.events {
                if let request = event.request {
                    conv.applyApprovalRequest(request, cursor: event.cursor)
                } else if let update = event.params {
                    conv.apply(update.update, cursor: event.cursor)
                }
            }
            if let cursor = response.cursor {
                conv.advanceCursor(to: cursor)
            }
        }

        return response
    }

    /// Sets a session config option via `session/set_config_option`. Allowed
    /// while the agent is generating. The response's full `configOptions`
    /// list replaces local state. When only legacy `modes` exist and the
    /// synthetic mode option is chosen, falls back to `session/set_mode`.
    @discardableResult
    func setConfigOption(sessionId: String, configId: String, value: String) async throws -> [SessionConfigOption] {
        guard isConnected() else {
            throw ConnectionError.notConnected
        }

        let current = conversation(for: sessionId)
        // Prefer configOptions; only the legacy modes API uses set_mode.
        if current.configOptions.isEmpty, current.modes != nil {
            let params: [String: AnyCodable] = [
                "sessionId": AnyCodable(sessionId),
                "modeId": AnyCodable(value),
            ]
            _ = try await rpc.request("session/set_mode", params: params)
            mutateConversation(sessionId) { conv in
                conv.applyCurrentMode(value)
            }
            return conversation(for: sessionId).selectableConfigOptions
        }

        let params: [String: AnyCodable] = [
            "sessionId": AnyCodable(sessionId),
            "configId": AnyCodable(configId),
            "value": AnyCodable(value),
        ]
        let result = try await rpc.request("session/set_config_option", params: params)
        let response = try result.decode(SetConfigOptionResponse.self)
        mutateConversation(sessionId) { conv in
            conv.replaceConfigOptions(response.configOptions)
        }
        return response.configOptions
    }

    /// Sends a text prompt to the session. The message is optimistically
    /// inserted into the transcript as a local user bubble while the request is
    /// in flight.
    @discardableResult
    func sendPrompt(sessionId: String, text: String) async throws -> String? {
        try await sendPrompt(sessionId: sessionId, prompt: [.text(text)])
    }

    /// Sends a structured prompt (text + `file_ref` references) to the session.
    /// Reference blocks survive verbatim on the wire so the companion can
    /// expand them into content blocks the agent reads (issue #8). The
    /// optimistic bubble shows the text plus one 📎 line per reference.
    @discardableResult
    func sendPrompt(sessionId: String, prompt: [PromptBlock]) async throws -> String? {
        guard isConnected() else {
            throw ConnectionError.notConnected
        }
        // Drop blank text blocks; keep references. An all-blank prompt is an
        // error, same as the legacy text-only guard below.
        let blocks = prompt.compactMap { block -> PromptBlock? in
            switch block {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : .text(trimmed)
            case .fileRef:
                return block
            }
        }
        guard !blocks.isEmpty else {
            throw ConnectionError.rpcError(code: -32602, message: "Empty prompt")
        }

        let bubbleText = blocks.map(\.displayText).joined(separator: "\n")
        mutateConversation(sessionId) { conv in
            conv.isSending = true
            conv.errorMessage = nil
            conv.transcript.appendLocalUserMessage(bubbleText)
        }
        defer {
            mutateConversation(sessionId) { conv in
                conv.isSending = false
                conv.transcript.markIdle()
            }
        }

        let wireBlocks = blocks.map { block -> AnyCodable in
            switch block {
            case .text(let text):
                return AnyCodable(["type": AnyCodable("text"), "text": AnyCodable(text)])
            case .fileRef(let path):
                return AnyCodable(["type": AnyCodable("file_ref"), "path": AnyCodable(path)])
            }
        }
        let params: [String: AnyCodable] = [
            "sessionId": AnyCodable(sessionId),
            "prompt": AnyCodable(wireBlocks),
        ]

        do {
            let result = try await rpc.request("session/prompt", params: params)
            let response = try result.decode(PromptResponse.self)
            return response.stopReason
        } catch let error as ConnectionError {
            mutateConversation(sessionId) { conv in
                conv.errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    /// Issues a `session/cancel` notification to stop the current generation.
    /// Safe to call repeatedly; a no-op when nothing is in flight.
    func cancelSession(id sessionId: String) async throws {
        guard isConnected() else {
            throw ConnectionError.notConnected
        }
        let params: [String: AnyCodable] = ["sessionId": AnyCodable(sessionId)]
        try await rpc.notify("session/cancel", params: params)
        mutateConversation(sessionId) { conv in
            conv.transcript.markIdle()
            conv.isSending = false
        }
    }

    // MARK: - Session update intake

    /// Applies one live `session/update` frame to the owning conversation.
    func applySessionUpdate(_ notification: SessionUpdateNotification, cursor: Int?) {
        mutateConversation(notification.sessionId) { conv in
            conv.apply(notification.update, cursor: cursor)
        }
    }

    // MARK: - Permissions

    /// Applies a live `session/request_permission` request, adding a pending
    /// approval card to the session's transcript.
    func applyPermissionRequest(_ request: PermissionRequest) {
        mutateConversation(request.sessionId) { conv in
            conv.applyApprovalRequest(request, cursor: nil)
        }
    }

    /// Responds to a pending permission request, echoing the request's JSON-RPC
    /// id with the ADR-005 result shape. Only the first answer counts: once the
    /// card is terminal (this device or another), further calls are silent
    /// no-ops — nothing is sent, nothing errors, nothing executes twice.
    func respondToPermission(sessionId: String, requestId: JsonRpcId, option: PermissionOption) async throws {
        guard isConnected() else {
            throw ConnectionError.notConnected
        }

        let state: PermissionState = option.isAllow
            ? .approved(optionId: option.optionId)
            : .rejected
        let transitioned = mutateConversation(sessionId) { conv in
            conv.resolveApproval(requestId: requestId, state: state)
        }
        guard transitioned else { return }

        do {
            try await rpc.respond(id: requestId, result: option.wireResult)
        } catch {
            // Put the card back to pending so the user can retry.
            mutateConversation(sessionId) { conv in
                _ = conv.revertApproval(requestId: requestId)
            }
            throw error
        }
    }

    /// Drops all conversation state, e.g. on sign-out.
    func clearAll() {
        conversations = [:]
    }

    @discardableResult
    private func mutateConversation<T>(_ sessionId: String, _ update: (inout SessionConversation) -> T) -> T {
        var conv = conversation(for: sessionId)
        let result = update(&conv)
        conversations[sessionId] = conv
        return result
    }
}
