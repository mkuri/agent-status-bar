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

    func testImmediateSoundOnceOnWaitingStateEntry() {
        let model = StateModel()
        // First evaluate primes silently, even for an already-waiting session.
        let first = model.evaluate([snap("a", .running, sinceAgo: 1)],
                                   activePIDs: [], now: now, config: config)
        XCTAssertTrue(first.soundsToPlay.isEmpty)
        // Session enters permission (state change resets since).
        let entered = [SessionSnapshot(sessionID: "a", state: .permission,
                                       since: now.addingTimeInterval(10),
                                       cwd: "/tmp/proj", pid: 100,
                                       updatedAt: now.addingTimeInterval(10))]
        let second = model.evaluate(entered, activePIDs: [],
                                    now: now.addingTimeInterval(11), config: config)
        XCTAssertEqual(second.soundsToPlay, ["Glass"])  // follows sound_permission
        let third = model.evaluate(entered, activePIDs: [],
                                   now: now.addingTimeInterval(15), config: config)
        XCTAssertTrue(third.soundsToPlay.isEmpty)
    }

    func testImmediateIdleSoundOnEntry() {
        let model = StateModel()
        _ = model.evaluate([snap("a", .running, sinceAgo: 1)],
                           activePIDs: [], now: now, config: config)
        let idle = [SessionSnapshot(sessionID: "a", state: .idle,
                                    since: now.addingTimeInterval(5),
                                    cwd: "/tmp/proj", pid: 100,
                                    updatedAt: now.addingTimeInterval(5))]
        let out = model.evaluate(idle, activePIDs: [],
                                 now: now.addingTimeInterval(6), config: config)
        XCTAssertEqual(out.soundsToPlay, ["Tink"])  // follows sound_idle
    }

    func testImmediateSoundFollowsThresholdSoundUnlessOverridden() {
        var follow = config
        follow.soundPermission = "Hero"
        let model = StateModel()
        _ = model.evaluate([snap("a", .running, sinceAgo: 1)],
                           activePIDs: [], now: now, config: follow)
        let entered = [SessionSnapshot(sessionID: "a", state: .permission,
                                       since: now.addingTimeInterval(10),
                                       cwd: "/tmp/proj", pid: 100,
                                       updatedAt: now.addingTimeInterval(10))]
        XCTAssertEqual(model.evaluate(entered, activePIDs: [],
                                      now: now.addingTimeInterval(11),
                                      config: follow).soundsToPlay, ["Hero"])

        var overridden = config
        overridden.immediateSoundIdle = "Ping"
        let model2 = StateModel()
        _ = model2.evaluate([snap("b", .running, sinceAgo: 1)],
                            activePIDs: [], now: now, config: overridden)
        let idled = [SessionSnapshot(sessionID: "b", state: .idle,
                                     since: now.addingTimeInterval(5),
                                     cwd: "/tmp/proj", pid: 100,
                                     updatedAt: now.addingTimeInterval(5))]
        XCTAssertEqual(model2.evaluate(idled, activePIDs: [],
                                       now: now.addingTimeInterval(6),
                                       config: overridden).soundsToPlay, ["Ping"])
    }

    func testImmediateSoundSuppressedOnFirstEvaluate() {
        let out = StateModel().evaluate([snap("a", .permission, sinceAgo: 5)],
                                        activePIDs: [], now: now, config: config)
        XCTAssertTrue(out.soundsToPlay.isEmpty)
    }

    func testImmediateSoundDisabledByEmptyString() {
        var c = config
        c.immediateSoundPermission = ""
        let model = StateModel()
        _ = model.evaluate([snap("a", .running, sinceAgo: 1)],
                           activePIDs: [], now: now, config: c)
        let entered = [SessionSnapshot(sessionID: "a", state: .permission,
                                       since: now.addingTimeInterval(10),
                                       cwd: "/tmp/proj", pid: 100,
                                       updatedAt: now.addingTimeInterval(10))]
        let out = model.evaluate(entered, activePIDs: [],
                                 now: now.addingTimeInterval(11), config: c)
        XCTAssertTrue(out.soundsToPlay.isEmpty)
    }

    func testThresholdBoundaryIsInclusive() {
        let perm = StateModel().evaluate([snap("a", .permission, sinceAgo: 300)],
                                         activePIDs: [], now: now, config: config)
        XCTAssertEqual(perm.soundsToPlay, ["Glass"])
        XCTAssertTrue(perm.rows.allSatisfy(\.overThreshold))

        let idle = StateModel().evaluate([snap("b", .idle, sinceAgo: 300)],
                                         activePIDs: [], now: now, config: config)
        XCTAssertEqual(idle.soundsToPlay, ["Tink"])
        XCTAssertTrue(idle.rows.allSatisfy(\.overThreshold))
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
        let sessions = [snap("a", .permission, sinceAgo: 301)]
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
        // Entering permission already past the threshold plays the threshold
        // alert only — the immediate entry sound is suppressed on the same
        // tick so one moment never produces two sounds.
        XCTAssertEqual(again.soundsToPlay, ["Glass"])
    }

    func testBlinkDisabledByConfig() {
        var c = config
        c.blink = false
        let out = StateModel().evaluate([snap("a", .permission, sinceAgo: 301)],
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

    func testFirstSightIdleIsSilentThenFinishRings() {
        let model = StateModel()
        // Brand-new session first seen in idle (SessionStart) — no ding.
        let start = model.evaluate([snap("a", .idle, sinceAgo: 1)],
                                   activePIDs: [], now: now, config: config)
        XCTAssertTrue(start.soundsToPlay.isEmpty)
        // Turn starts (running), then finishes (idle again) — the finish rings.
        _ = model.evaluate([snap("a", .running, sinceAgo: 1)],
                           activePIDs: [], now: now.addingTimeInterval(10), config: config)
        let finished = [SessionSnapshot(sessionID: "a", state: .idle,
                                        since: now.addingTimeInterval(20),
                                        cwd: "/tmp/proj", pid: 100,
                                        updatedAt: now.addingTimeInterval(20))]
        let out = model.evaluate(finished, activePIDs: [],
                                 now: now.addingTimeInterval(21), config: config)
        XCTAssertEqual(out.soundsToPlay, ["Tink"])
    }

    func testFirstSightOverThresholdStillNags() {
        // App restart: a session already idle past threshold nags on first
        // sight but plays no entry sound.
        let out = StateModel().evaluate([snap("a", .idle, sinceAgo: 400)],
                                        activePIDs: [], now: now, config: config)
        XCTAssertEqual(out.soundsToPlay, ["Tink"])
    }

    func testNewSessionAppearingAfterPrimeIsSilent() {
        let model = StateModel()
        // Prime the model with an existing running session.
        _ = model.evaluate([snap("a", .running, sinceAgo: 5)],
                           activePIDs: [], now: now, config: config)
        // A brand-new session appears in idle (SessionStart) after the model is
        // already primed — it must be silent (no entry ding).
        let out = model.evaluate(
            [snap("a", .running, sinceAgo: 10), snap("b", .idle, sinceAgo: 1)],
            activePIDs: [], now: now.addingTimeInterval(5), config: config)
        XCTAssertTrue(out.soundsToPlay.isEmpty)
    }

    func testCountsAggregateAcrossAgentsAndRowsCarryAgent() {
        let out = StateModel().evaluate(
            [SessionSnapshot(sessionID: "a", state: .running,
                             since: now.addingTimeInterval(-5), cwd: "/x/api",
                             pid: 100, updatedAt: now, agent: .claude),
             SessionSnapshot(sessionID: "b", state: .running,
                             since: now.addingTimeInterval(-5), cwd: "/x/web",
                             pid: 101, updatedAt: now, agent: .antigravity),
             SessionSnapshot(sessionID: "c", state: .idle,
                             since: now.addingTimeInterval(-5), cwd: "/x/infra",
                             pid: 102, updatedAt: now, agent: .antigravity)],
            activePIDs: [], now: now, config: config)
        XCTAssertEqual(out.segments, [
            BarSegment(state: .running, count: 2, blinking: false),
            BarSegment(state: .idle, count: 1, blinking: false),
        ])
        let byName = Dictionary(uniqueKeysWithValues: out.rows.map { ($0.name, $0.agent) })
        XCTAssertEqual(byName["api"], .claude)
        XCTAssertEqual(byName["web"], .antigravity)
        XCTAssertEqual(byName["infra"], .antigravity)
    }
}
