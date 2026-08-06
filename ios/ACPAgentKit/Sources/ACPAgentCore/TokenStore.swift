import Foundation
#if canImport(Security)
import Security
#endif

public protocol TokenStore: Sendable {
    func saveToken(_ token: String, for endpoint: String) throws
    func loadToken(for endpoint: String) throws -> String?
    func deleteToken(for endpoint: String) throws
    func loadEndpoint() -> String?
    func saveEndpoint(_ endpoint: String)
}

public final class KeychainTokenStore: TokenStore, Sendable {
    private let service: String
    private let endpointDefaultsKey = "acp_agent_endpoint"

    public init(service: String = "com.acp-agent.ios") {
        self.service = service
    }

    public func saveToken(_ token: String, for endpoint: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpoint
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.from(status: updateStatus)
            }
        } else {
            var newQuery = query
            newQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(newQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.from(status: addStatus)
            }
        }
    }

    public func loadToken(for endpoint: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpoint,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.from(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func deleteToken(for endpoint: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpoint
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.from(status: status)
        }
    }

    public func loadEndpoint() -> String? {
        UserDefaults.standard.string(forKey: endpointDefaultsKey)
    }

    public func saveEndpoint(_ endpoint: String) {
        UserDefaults.standard.set(endpoint, forKey: endpointDefaultsKey)
    }
}

public enum KeychainError: Error, Equatable, Sendable {
    case invalidData
    case unhandledError(status: OSStatus)
    case itemNotFound

    static func from(status: OSStatus) -> KeychainError {
        switch status {
        case errSecItemNotFound: return .itemNotFound
        default: return .unhandledError(status: status)
        }
    }
}
