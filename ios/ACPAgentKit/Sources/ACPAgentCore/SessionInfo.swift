import Foundation

public enum SessionStatus: String, Codable, Equatable, Sendable {
    case active
    case ended
    case interrupted
}

public struct SessionInfo: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let cwd: String
    public let status: SessionStatus
    public let hasPendingApproval: Bool
    public let createdAt: TimeInterval
    public let lastActiveAt: TimeInterval

    public init(id: String, cwd: String, status: SessionStatus, hasPendingApproval: Bool, createdAt: TimeInterval, lastActiveAt: TimeInterval) {
        self.id = id
        self.cwd = cwd
        self.status = status
        self.hasPendingApproval = hasPendingApproval
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }

    public var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    public var createdDate: Date { Date(timeIntervalSince1970: createdAt / 1000) }
    public var lastActiveDate: Date { Date(timeIntervalSince1970: lastActiveAt / 1000) }
}

public struct SessionListResponse: Codable, Equatable, Sendable {
    public let sessions: [SessionInfo]

    public init(sessions: [SessionInfo]) {
        self.sessions = sessions
    }
}

public struct AuthResponse: Codable, Equatable, Sendable {
    public let ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

/// One project's sessions. Identity is the full `cwd`, so two checkouts that
/// share a directory name stay separate groups; `name` is only for display.
public struct ProjectGroup: Equatable, Identifiable, Sendable {
    public let id: String
    public let cwd: String
    public let name: String
    public let sessions: [SessionInfo]
    public let pendingCount: Int

    public init(cwd: String, sessions: [SessionInfo]) {
        self.id = cwd
        self.cwd = cwd
        self.name = (cwd as NSString).lastPathComponent
        self.sessions = sessions.sorted { $0.lastActiveAt > $1.lastActiveAt }
        self.pendingCount = sessions.filter { $0.hasPendingApproval }.count
    }
}

extension [SessionInfo] {
    public func groupedByProject() -> [ProjectGroup] {
        let groups = Dictionary(grouping: self) { $0.cwd }
        return groups.map { ProjectGroup(cwd: $0.key, sessions: $0.value) }
            .sorted { groupA, groupB in
                let latestA = groupA.sessions.map { $0.lastActiveAt }.max() ?? 0
                let latestB = groupB.sessions.map { $0.lastActiveAt }.max() ?? 0
                return latestA > latestB
            }
    }
}
