import XCTest
@testable import AgentStatusBar

final class SnapshotTests: XCTestCase {
    let fixture = #"""
    {"version": 1, "session_id": "abc", "state": "permission",
     "since": 1000.0, "cwd": "/Users/x/proj", "pid": 42,
     "updated_at": 1100.0, "future_field": "ignored"}
    """#

    func testDecodeContractFixture() throws {
        let s = try XCTUnwrap(SessionSnapshot.decode(Data(fixture.utf8)))
        XCTAssertEqual(s.sessionID, "abc")
        XCTAssertEqual(s.state, .permission)
        XCTAssertEqual(s.since, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(s.cwd, "/Users/x/proj")
        XCTAssertEqual(s.pid, 42)
        XCTAssertEqual(s.updatedAt, Date(timeIntervalSince1970: 1100))
    }

    func testDecodeNewerVersionSkipped() {
        let newer = fixture.replacingOccurrences(of: #""version": 1"#,
                                                with: #""version": 2"#)
        XCTAssertNil(SessionSnapshot.decode(Data(newer.utf8)))
    }

    func testDecodeGarbageReturnsNil() {
        XCTAssertNil(SessionSnapshot.decode(Data("{broken".utf8)))
        XCTAssertNil(SessionSnapshot.decode(Data("{}".utf8)))
    }

    func testDecodeUnknownStateReturnsNil() {
        let odd = fixture.replacingOccurrences(of: "permission", with: "sleeping")
        XCTAssertNil(SessionSnapshot.decode(Data(odd.utf8)))
    }

    func testDecodeInjectsAgentFromCaller() throws {
        let claude = try XCTUnwrap(SessionSnapshot.decode(Data(fixture.utf8)))
        XCTAssertEqual(claude.agent, .claude)  // default
        let agy = try XCTUnwrap(
            SessionSnapshot.decode(Data(fixture.utf8), agent: .antigravity))
        XCTAssertEqual(agy.agent, .antigravity)
    }

    func snap(_ id: String, pid: Int32, updatedAgo: TimeInterval, now: Date) -> SessionSnapshot {
        SessionSnapshot(sessionID: id, state: .running,
                        since: now.addingTimeInterval(-updatedAgo), cwd: "/p",
                        pid: pid, updatedAt: now.addingTimeInterval(-updatedAgo))
    }

    func testSplitStaleDeadPid() {
        let now = Date()
        let live = snap("a", pid: 1, updatedAgo: 10, now: now)
        let dead = snap("b", pid: 2, updatedAgo: 10, now: now)
        let result = StateModel.splitStale([live, dead], livePIDs: [1], now: now)
        XCTAssertEqual(result.live, [live])
        XCTAssertEqual(result.stale.map(\.sessionID), ["b"])
    }

    func testSplitStaleOldFile() {
        let now = Date()
        let old = snap("a", pid: 1, updatedAgo: StateModel.staleAge + 1, now: now)
        let result = StateModel.splitStale([old], livePIDs: [1], now: now)
        XCTAssertEqual(result.live, [])
        XCTAssertEqual(result.stale.map(\.sessionID), ["a"])
    }
}
