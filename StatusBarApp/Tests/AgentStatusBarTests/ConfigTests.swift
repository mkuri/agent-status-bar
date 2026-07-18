import XCTest
@testable import AgentStatusBar

final class ConfigTests: XCTestCase {
    func testDefaults() {
        let c = Config()
        XCTAssertEqual(c.permissionAlertSec, 120)
        XCTAssertEqual(c.idleAlertSec, 300)
        XCTAssertEqual(c.soundPermission, "Glass")
        XCTAssertEqual(c.soundIdle, "Tink")
        XCTAssertTrue(c.blink)
        XCTAssertTrue(c.activityDetection)
        XCTAssertEqual(c.activityCpuThresholdPct, 3.0)
        XCTAssertEqual(c.immediateSoundPermission, "Pop")
        XCTAssertEqual(c.immediateSoundIdle, "Purr")
    }

    func testImmediateSoundsDisabledByEmptyString() {
        let c = Config(raw: ["immediate_sound_permission": "", "immediate_sound_idle": ""])
        XCTAssertEqual(c.immediateSoundPermission, "")
        XCTAssertEqual(c.immediateSoundIdle, "")
    }

    func testPartialOverlayKeepsOtherDefaults() {
        let c = Config(raw: ["idle_alert_sec": 60, "blink": false])
        XCTAssertEqual(c.idleAlertSec, 60)
        XCTAssertFalse(c.blink)
        XCTAssertEqual(c.permissionAlertSec, 120)
        XCTAssertEqual(c.soundPermission, "Glass")
    }

    func testIntegerJSONNumbersAccepted() {
        let c = Config(raw: ["permission_alert_sec": 90])
        XCTAssertEqual(c.permissionAlertSec, 90)
    }

    func testLoadMissingFileGivesDefaults() {
        let c = Config.load(from: URL(fileURLWithPath: "/nonexistent/config.json"))
        XCTAssertEqual(c, Config())
    }

    func testLoadRealFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"sound_permission": "Ping"}"#.utf8).write(to: url)
        XCTAssertEqual(Config.load(from: url).soundPermission, "Ping")
    }
}
