import Foundation

public struct ServerEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let useTLS: Bool

    public init(host: String, port: Int, useTLS: Bool = false) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = useTLS ? "wss" : "ws"
        components.host = host
        components.port = port
        return components.url
    }

    public var displayString: String {
        "\(useTLS ? "wss" : "ws")://\(host):\(port)"
    }

    /// Parses user-typed endpoints. Accepts bare `host:port`, or full
    /// `ws://`/`wss://`/`http://`/`https://` URLs, mapping http schemes onto
    /// their WebSocket equivalents.
    public static func parse(_ input: String) -> ServerEndpoint? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var working = trimmed
        var useTLS = false
        var hadScheme = false

        for (scheme, tls) in [("wss://", true), ("ws://", false), ("https://", true), ("http://", false)] {
            if working.lowercased().hasPrefix(scheme) {
                working = String(working.dropFirst(scheme.count))
                useTLS = tls
                hadScheme = true
                break
            }
        }

        if let slashIndex = working.firstIndex(of: "/") {
            working = String(working[working.startIndex..<slashIndex])
        }
        guard !working.isEmpty else { return nil }

        let host: String
        let port: Int
        if let colonIndex = working.lastIndex(of: ":") {
            host = String(working[working.startIndex..<colonIndex])
            let portString = String(working[working.index(after: colonIndex)...])
            guard let parsedPort = Int(portString), (1...65535).contains(parsedPort) else { return nil }
            port = parsedPort
        } else {
            host = working
            port = useTLS && hadScheme ? 443 : 8787
        }

        guard !host.isEmpty, !host.contains(" ") else { return nil }
        return ServerEndpoint(host: host, port: port, useTLS: useTLS)
    }
}
