import XCTest
@testable import AgentStatusBar

final class ProcessProbeTests: XCTestCase {
    func testParsePSSkipsGarbageLines() {
        let text = """
            1     0  0.0
          200     1 12.5
        garbage line
          201   200  3.25
        """
        let entries = ProcessProbe.parsePS(text)
        XCTAssertEqual(entries, [
            ProcessProbe.PSEntry(pid: 1, ppid: 0, pcpu: 0.0),
            ProcessProbe.PSEntry(pid: 200, ppid: 1, pcpu: 12.5),
            ProcessProbe.PSEntry(pid: 201, ppid: 200, pcpu: 3.25),
        ])
    }

    func testTreeCPUSumsDescendantsOnly() {
        let entries = [
            ProcessProbe.PSEntry(pid: 10, ppid: 1, pcpu: 1.0),
            ProcessProbe.PSEntry(pid: 11, ppid: 10, pcpu: 2.0),
            ProcessProbe.PSEntry(pid: 12, ppid: 11, pcpu: 4.0),
            ProcessProbe.PSEntry(pid: 99, ppid: 1, pcpu: 50.0),
        ]
        let cpu = ProcessProbe.treeCPU(roots: [10, 99], entries: entries)
        XCTAssertEqual(cpu[10], 7.0)
        XCTAssertEqual(cpu[99], 50.0)
    }

    func testTreeCPUUnknownRootIsZero() {
        XCTAssertEqual(ProcessProbe.treeCPU(roots: [123], entries: [])[123], 0.0)
    }

    func testIsAliveForOwnProcessAndBogusPid() {
        XCTAssertTrue(ProcessProbe.isAlive(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(ProcessProbe.isAlive(Int32.max))  // beyond any real PID
    }

    func testSamplePSContainsOwnProcess() {
        let own = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(ProcessProbe.samplePS().contains { $0.pid == own })
    }
}
