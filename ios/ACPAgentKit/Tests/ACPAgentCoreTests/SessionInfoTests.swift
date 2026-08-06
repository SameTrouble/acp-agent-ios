import Foundation
import Testing
@testable import ACPAgentCore

@Suite struct SessionInfoTests {

    @Test func projectNameUsesLastPathComponent() {
        let s = SessionInfo(
            id: "sess_1", cwd: "/Users/alice/code/my-project",
            status: .active, hasPendingApproval: false,
            createdAt: 0, lastActiveAt: 0
        )
        #expect(s.projectName == "my-project")
    }

    @Test func projectNameForRootPath() {
        let s = SessionInfo(
            id: "sess_1", cwd: "/",
            status: .active, hasPendingApproval: false,
            createdAt: 0, lastActiveAt: 0
        )
        #expect(s.projectName == "/")
    }

    @Test func groupingSortsSessionsNewestFirst() {
        let sessions = [
            SessionInfo(id: "s1", cwd: "/a/my-project", status: .active, hasPendingApproval: false, createdAt: 100, lastActiveAt: 300),
            SessionInfo(id: "s2", cwd: "/a/my-project", status: .ended, hasPendingApproval: true, createdAt: 200, lastActiveAt: 400),
        ]

        let groups = sessions.groupedByProject()
        #expect(groups.count == 1)
        #expect(groups[0].name == "my-project")
        #expect(groups[0].sessions.map { $0.id } == ["s2", "s1"])
        #expect(groups[0].pendingCount == 1)
    }

    @Test func groupingKeepsSeparateDirsApart() {
        let sessions = [
            SessionInfo(id: "s1", cwd: "/a/web", status: .active, hasPendingApproval: false, createdAt: 100, lastActiveAt: 300),
            SessionInfo(id: "s2", cwd: "/b/web", status: .ended, hasPendingApproval: false, createdAt: 200, lastActiveAt: 400),
        ]

        let groups = sessions.groupedByProject()
        #expect(groups.count == 2)
        #expect(Set(groups.map { $0.id }) == ["/a/web", "/b/web"])
        #expect(Set(groups.map { $0.name }) == ["web"]) // same display name, different identity
    }

    @Test func groupingCountsPendingPerGroup() {
        let sessions = [
            SessionInfo(id: "s1", cwd: "/proj-a", status: .active, hasPendingApproval: true, createdAt: 100, lastActiveAt: 300),
            SessionInfo(id: "s2", cwd: "/proj-a", status: .active, hasPendingApproval: true, createdAt: 200, lastActiveAt: 400),
            SessionInfo(id: "s3", cwd: "/proj-b", status: .active, hasPendingApproval: false, createdAt: 50, lastActiveAt: 250),
        ]

        let groups = sessions.groupedByProject()
        let projA = groups.first { $0.id == "/proj-a" }
        #expect(projA?.pendingCount == 2)
        let projB = groups.first { $0.id == "/proj-b" }
        #expect(projB?.pendingCount == 0)
    }

    @Test func groupOrderByMostRecentSession() {
        let sessions = [
            SessionInfo(id: "s1", cwd: "/older", status: .active, hasPendingApproval: false, createdAt: 0, lastActiveAt: 100),
            SessionInfo(id: "s2", cwd: "/newer", status: .active, hasPendingApproval: false, createdAt: 0, lastActiveAt: 500),
        ]
        let groups = sessions.groupedByProject()
        #expect(groups[0].name == "newer")
        #expect(groups[1].name == "older")
    }

    @Test func emptyList() {
        #expect([SessionInfo]().groupedByProject() == [])
    }

    @Test func dateConversions() {
        let s = SessionInfo(id: "s1", cwd: "/p", status: .active, hasPendingApproval: false,
                            createdAt: 1_700_000_000_000, lastActiveAt: 1_700_000_001_000)
        #expect(s.createdDate.timeIntervalSince1970 == 1_700_000_000)
        #expect(s.lastActiveDate.timeIntervalSince1970 == 1_700_000_001)
    }
}
