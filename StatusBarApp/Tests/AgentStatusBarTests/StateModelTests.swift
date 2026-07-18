import XCTest
@testable import AgentStatusBar

final class StateModelTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let config = Config()

    func snap(_ id: String, _ state: SessionState, sinceAgo: TimeInterval,
              pid: Int32 = 100, cwd: String = "/tmp/proj") -> SessionSnapshot {
        SessionSnapshot(sessionID: id, state: state,
                        since: now.addingTimeInterval(-sinceAgo),
                        cwd: cwd, pid: pid, updatedAt: now)
    }

    func testCountsOrderAndZeroHiding() {
        let out = StateModel().evaluate(
            [snap("a", .running, sinceAgo: 5), snap("b", .running, sinceAgo: 5),
             snap("c", .idle, sinceAgo: 5)],
            activePIDs: [], now: now, config: config)
        XCTAssertEqual(out.segments, [
            BarSegment(state: .running, count: 2, blinking: false),
            BarSegment(state: .idle, count: 1, blinking: false),
        ])
        XCTAssertTrue(out.soundsToPlay.isEmpty)
    }

    func testThresholdBoundaryIsInclusive() {
        let out = StateModel().evaluate(
            [snap("a", .permission, sinceAgo: 120), snap("b", .idle, sinceAgo: 300)],
            activePIDs: [], now: now, config: config)
        XCTAssertEqual(out.soundsToPlay, ["Glass", "Tink"])
        XCTAssertTrue(out.rows.allSatisfy(\.overThreshold))
    }

    func testActivityOverrideDisplaysPermissionAsRunning() {
        let out = StateModel().evaluate(
            [snap("a", .permission, sinceAgo: 500, pid: 7)],
            activePIDs: [7], now: now, config: config)
        XCTAssertEqual(out.segments, [BarSegment(state: .running, count: 1, blinking: false)])
        XCTAssertTrue(out.soundsToPlay.isEmpty)  // no permission alert while overridden
    }

    func testActivityOverrideDisabledByConfig() {
        var c = config
        c.activityDetection = false
        let out = StateModel().evaluate(
            [snap("a", .permission, sinceAgo: 5, pid: 7)],
            activePIDs: [7], now: now, config: c)
        XCTAssertEqual(out.segments, [BarSegment(state: .permission, count: 1, blinking: false)])
    }

    func testPermissionThresholdFiresSoundOnceAndBlinks() {
        let model = StateModel()
        let sessions = [snap("a", .permission, sinceAgo: 121)]
        let first = model.evaluate(sessions, activePIDs: [], now: now, config: config)
        XCTAssertEqual(first.soundsToPlay, ["Glass"])
        XCTAssertEqual(first.segments, [BarSegment(state: .permission, count: 1, blinking: true)])
        XCTAssertTrue(first.rows[0].overThreshold)

        let second = model.evaluate(sessions, activePIDs: [], now: now.addingTimeInterval(5),
                                    config: config)
        XCTAssertTrue(second.soundsToPlay.isEmpty)          // alert-once
        XCTAssertTrue(second.segments[0].blinking)          // keeps blinking
    }

    func testIdleThresholdUsesIdleSound() {
        let out = StateModel().evaluate([snap("a", .idle, sinceAgo: 301)],
                                        activePIDs: [], now: now, config: config)
        XCTAssertEqual(out.soundsToPlay, ["Tink"])
    }

    func testUnderThresholdNoAlert() {
        let out = StateModel().evaluate(
            [snap("a", .permission, sinceAgo: 119), snap("b", .idle, sinceAgo: 299)],
            activePIDs: [], now: now, config: config)
        XCTAssertTrue(out.soundsToPlay.isEmpty)
        XCTAssertFalse(out.segments.contains { $0.blinking })
    }

    func testAlertRearmsAfterStateChange() {
        let model = StateModel()
        _ = model.evaluate([snap("a", .permission, sinceAgo: 121)],
                           activePIDs: [], now: now, config: config)
        // session went running (state change resets since), then waits again
        _ = model.evaluate([snap("a", .running, sinceAgo: 1)],
                           activePIDs: [], now: now.addingTimeInterval(10), config: config)
        let again = model.evaluate(
            [SessionSnapshot(sessionID: "a", state: .permission,
                             since: now.addingTimeInterval(100),
                             cwd: "/tmp/proj", pid: 100,
                             updatedAt: now.addingTimeInterval(400))],
            activePIDs: [], now: now.addingTimeInterval(400), config: config)
        XCTAssertEqual(again.soundsToPlay, ["Glass"])
    }

    func testBlinkDisabledByConfig() {
        var c = config
        c.blink = false
        let out = StateModel().evaluate([snap("a", .permission, sinceAgo: 121)],
                                        activePIDs: [], now: now, config: c)
        XCTAssertEqual(out.soundsToPlay, ["Glass"])         // sound still fires
        XCTAssertFalse(out.segments[0].blinking)
    }

    func testRowOrderingAndNames() {
        let out = StateModel().evaluate(
            [snap("r", .running, sinceAgo: 5, cwd: "/x/api"),
             snap("i", .idle, sinceAgo: 5, cwd: "/x/web"),
             snap("p", .permission, sinceAgo: 5, cwd: "/x/infra")],
            activePIDs: [], now: now, config: config)
        XCTAssertEqual(out.rows.map(\.name), ["infra", "web", "api"])
        XCTAssertEqual(out.rows.map(\.state), [.permission, .idle, .running])
    }

    func testFormatElapsed() {
        XCTAssertEqual(formatElapsed(45), "45s")
        XCTAssertEqual(formatElapsed(180), "3m")
        XCTAssertEqual(formatElapsed(3900), "1h 5m")
    }
}
