import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol WebSocketTransport: AnyObject, Sendable {
    var onMessage: ((String) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }
    func connect(url: URL, timeout: TimeInterval) async throws
    func send(_ text: String) async throws
    func disconnect() async
}

public enum ConnectionError: Error, Equatable, Sendable {
    case invalidURL
    case connectionFailed(String)
    case notConnected
    case requestTimeout
    case unauthorized
    case rpcError(code: Int, message: String)
}

private actor TransportState {
    enum Phase {
        case idle
        case connecting(CheckedContinuation<Void, Error>)
        case open
        case closed
    }

    var phase: Phase = .idle

    func beginConnect(_ continuation: CheckedContinuation<Void, Error>) {
        phase = .connecting(continuation)
    }

    func completeConnect() -> CheckedContinuation<Void, Error>? {
        if case .connecting(let cont) = phase {
            phase = .open
            return cont
        }
        return nil
    }

    func close(error: Error) -> (CheckedContinuation<Void, Error>?, Bool) {
        switch phase {
        case .idle, .closed:
            return (nil, false)
        case .connecting(let cont):
            phase = .closed
            return (cont, false)
        case .open:
            phase = .closed
            return (nil, true)
        }
    }

    var isOpen: Bool {
        if case .open = phase { return true }
        return false
    }
}

public final class URLSessionWebSocketTransport: NSObject, WebSocketTransport, @unchecked Sendable {
    public var onMessage: ((String) -> Void)?
    public var onDisconnect: ((Error?) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let delegateQueue = OperationQueue()
    private let state = TransportState()

    public override init() {
        super.init()
        delegateQueue.maxConcurrentOperationCount = 1
    }

    public func connect(url: URL, timeout: TimeInterval = 10) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        try await withThrowingTimeout(seconds: timeout) { [weak self] in
            try await withCheckedThrowingContinuation { continuation in
                Task { [weak self] in
                    await self?.state.beginConnect(continuation)
                }
            }
        }

        receiveLoop()
    }

    public func send(_ text: String) async throws {
        guard let task = task, await state.isOpen else {
            throw ConnectionError.notConnected
        }
        try await task.send(.string(text))
    }

    public func disconnect() async {
        let (_, _) = await state.close(error: ConnectionError.notConnected)
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.onMessage?(text)
                }
                self.receiveLoop()
            case .failure(let error):
                Task { await self.handleClose(error: error) }
            }
        }
    }

    private func handleClose(error: Error?) async {
        let (connectCont, shouldNotify) = await state.close(error: error ?? ConnectionError.notConnected)
        if let connectCont {
            connectCont.resume(throwing: error ?? ConnectionError.connectionFailed("Connection closed"))
            return
        }
        if shouldNotify {
            onDisconnect?(error)
        }
    }
}

extension URLSessionWebSocketTransport: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task {
            if let cont = await state.completeConnect() {
                cont.resume()
            }
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) }
        let error = NSError(
            domain: "WebSocket",
            code: closeCode.rawValue,
            userInfo: reasonStr.map { [NSLocalizedDescriptionKey: $0] }
        )
        Task { await handleClose(error: error) }
    }
}

private func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ConnectionError.requestTimeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private actor JsonRpcState {
    var pending: [String: CheckedContinuation<AnyCodable, Error>] = [:]
    var nextId: Int = 0
    var isAuthenticated: Bool = false

    func nextRequestId() -> Int {
        nextId += 1
        return nextId
    }

    func addPending(id: String, continuation: CheckedContinuation<AnyCodable, Error>) {
        pending[id] = continuation
    }

    func removePending(id: String) -> CheckedContinuation<AnyCodable, Error>? {
        pending.removeValue(forKey: id)
    }

    func setAuthenticated(_ value: Bool) {
        isAuthenticated = value
    }

    func clearAll(error: Error) -> [CheckedContinuation<AnyCodable, Error>] {
        let all = Array(pending.values)
        pending.removeAll()
        isAuthenticated = false
        return all
    }
}

public final class JsonRpcClient: @unchecked Sendable {
    private let transport: any WebSocketTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let state = JsonRpcState()
    private var onNotification: ((JsonRpcNotification) -> Void)?
    private var onRequest: ((JsonRpcRequest) -> Void)?
    private let notificationQueue = DispatchQueue(label: "com.acp-agent.jsonrpc.notification")
    private let connectTimeout: TimeInterval

    public var onNotificationHandler: ((JsonRpcNotification) -> Void)? {
        get { notificationQueue.sync { onNotification } }
        set { notificationQueue.sync { onNotification = newValue } }
    }

    /// Delivers agent→client JSON-RPC requests (e.g. `session/request_permission`),
    /// which arrive with an `id` the client must eventually answer via `respond`.
    public var onRequestHandler: ((JsonRpcRequest) -> Void)? {
        get { notificationQueue.sync { onRequest } }
        set { notificationQueue.sync { onRequest = newValue } }
    }

    public init(transport: any WebSocketTransport, connectTimeout: TimeInterval = 10) {
        self.transport = transport
        self.connectTimeout = connectTimeout
        setupTransportHandlers()
    }

    private func setupTransportHandlers() {
        transport.onMessage = { [weak self] text in
            self?.handleMessage(text)
        }
        transport.onDisconnect = { [weak self] error in
            self?.handleDisconnect(error)
        }
    }

    public func connect(url: URL) async throws {
        try await transport.connect(url: url, timeout: connectTimeout)
    }

    public func disconnect() async {
        await transport.disconnect()
        let continuations = await state.clearAll(error: ConnectionError.notConnected)
        for cont in continuations {
            cont.resume(throwing: ConnectionError.notConnected)
        }
    }

    @discardableResult
    public func authenticate(token: String) async throws -> Bool {
        let result = try await request("auth", params: ["token": AnyCodable(token)])
        let response = try result.decode(AuthResponse.self)
        await state.setAuthenticated(response.ok)
        return response.ok
    }

    @discardableResult
    public func request(_ method: String, params: [String: AnyCodable]? = nil) async throws -> AnyCodable {
        let idNum = await state.nextRequestId()
        let id = JsonRpcId.number(idNum)
        let idKey = "\(idNum)"

        let request = JsonRpcRequest(id: id, method: method, params: params)
        let data = try encoder.encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectionError.connectionFailed("Failed to encode request")
        }

        return try await withCheckedThrowingContinuation { continuation in
            Task { [weak self] in
                guard let self else { return }
                await self.state.addPending(id: idKey, continuation: continuation)
                do {
                    try await self.transport.send(text)
                } catch {
                    let cont = await self.state.removePending(id: idKey)
                    cont?.resume(throwing: error)
                }
            }
        }
    }

    /// Fire-and-forget message with no `id`, so the peer must not reply.
    /// `session/cancel` is specified as a notification, not a request.
    public func notify(_ method: String, params: [String: AnyCodable]? = nil) async throws {
        let notification = JsonRpcNotification(method: method, params: params)
        let data = try encoder.encode(notification)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectionError.connectionFailed("Failed to encode notification")
        }
        try await transport.send(text)
    }

    /// Replies to an agent→client request, echoing its `id` (ADR-005 response
    /// expectations for `session/request_permission`).
    public func respond(id: JsonRpcId, result: AnyCodable) async throws {
        let response = JsonRpcResponse(id: id, result: result)
        let data = try encoder.encode(response)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectionError.connectionFailed("Failed to encode response")
        }
        try await transport.send(text)
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let message = try decoder.decode(JsonRpcMessage.self, from: data)
            switch message {
            case .response(let response):
                handleResponse(response)
            case .notification(let notification):
                notificationQueue.async { [weak self] in
                    self?.onNotification?(notification)
                }
            case .request(let request):
                notificationQueue.async { [weak self] in
                    self?.onRequest?(request)
                }
            }
        } catch {
            print("Failed to decode JSON-RPC message: \(error)")
        }
    }

    private func handleResponse(_ response: JsonRpcResponse) {
        let idKey: String
        switch response.id {
        case .number(let n): idKey = "\(n)"
        case .string(let s): idKey = s
        }

        Task { [weak self] in
            guard let self else { return }
            let cont = await self.state.removePending(id: idKey)
            guard let cont else { return }

            if let error = response.error {
                if error.isUnauthorized {
                    cont.resume(throwing: ConnectionError.unauthorized)
                } else {
                    cont.resume(throwing: ConnectionError.rpcError(code: error.code, message: error.message))
                }
                return
            }

            if let result = response.result {
                cont.resume(returning: result)
            } else {
                cont.resume(returning: AnyCodable(NSNull()))
            }
        }
    }

    private func handleDisconnect(_ error: Error?) {
        Task { [weak self] in
            guard let self else { return }
            let disconnectError = error ?? ConnectionError.notConnected
            let continuations = await self.state.clearAll(error: disconnectError)
            for cont in continuations {
                cont.resume(throwing: disconnectError)
            }
        }
    }
}
