import XCTest
@testable import AgentStatusBar

final class ProcessProbeTests: XCTestCase {
    func testIsAliveForOwnProcessAndBogusPid() {
        XCTAssertTrue(ProcessProbe.isAlive(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(ProcessProbe.isAlive(Int32.max))  // beyond any real PID
    }
}
