import Foundation

enum ProcessProbe {
    struct PSEntry: Equatable {
        let pid: Int32
        let ppid: Int32
        let pcpu: Double
    }

    static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func parsePS(_ text: String) -> [PSEntry] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  let pcpu = Double(fields[2]) else { return nil }
            return PSEntry(pid: pid, ppid: ppid, pcpu: pcpu)
        }
    }

    static func treeCPU(roots: Set<Int32>, entries: [PSEntry]) -> [Int32: Double] {
        var children: [Int32: [Int32]] = [:]
        var cpu: [Int32: Double] = [:]
        for e in entries {
            children[e.ppid, default: []].append(e.pid)
            cpu[e.pid] = e.pcpu
        }
        var result: [Int32: Double] = [:]
        for root in roots {
            var total = 0.0
            var stack = [root]
            var seen: Set<Int32> = []
            while let pid = stack.popLast() {
                guard seen.insert(pid).inserted else { continue }
                total += cpu[pid] ?? 0
                stack.append(contentsOf: children[pid] ?? [])
            }
            result[root] = total
        }
        return result
    }

    static func samplePS() -> [PSEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,pcpu="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parsePS(String(decoding: data, as: UTF8.self))
    }
}
