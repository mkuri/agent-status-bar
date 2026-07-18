import Foundation

enum SessionState: String {
    case running, permission, idle
}

struct SessionSnapshot: Equatable {
    let sessionID: String
    let state: SessionState
    let since: Date
    let cwd: String
    let pid: Int32
    let updatedAt: Date

    static let contractVersion = 1

    static func decode(_ data: Data) -> SessionSnapshot? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = raw["version"] as? Int, version <= contractVersion,
              let id = raw["session_id"] as? String,
              let stateRaw = raw["state"] as? String,
              let state = SessionState(rawValue: stateRaw),
              let since = raw["since"] as? Double,
              let pid = raw["pid"] as? Int,
              let updated = raw["updated_at"] as? Double
        else { return nil }
        return SessionSnapshot(
            sessionID: id,
            state: state,
            since: Date(timeIntervalSince1970: since),
            cwd: raw["cwd"] as? String ?? "",
            pid: Int32(pid),
            updatedAt: Date(timeIntervalSince1970: updated))
    }
}

final class StateModel {
    static let staleAge: TimeInterval = 24 * 3600

    static func splitStale(_ snapshots: [SessionSnapshot], livePIDs: Set<Int32>,
                           now: Date) -> (live: [SessionSnapshot], staleIDs: [String]) {
        var live: [SessionSnapshot] = []
        var staleIDs: [String] = []
        for s in snapshots {
            if livePIDs.contains(s.pid), now.timeIntervalSince(s.updatedAt) < Self.staleAge {
                live.append(s)
            } else {
                staleIDs.append(s.sessionID)
            }
        }
        return (live, staleIDs)
    }
}
