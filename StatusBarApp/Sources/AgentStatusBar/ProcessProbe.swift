import Foundation

enum ProcessProbe {
    static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
