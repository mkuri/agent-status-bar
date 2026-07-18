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
              let pidRaw = raw["pid"] as? Int,
              let pid = Int32(exactly: pidRaw),
              let updated = raw["updated_at"] as? Double
        else { return nil }
        return SessionSnapshot(
            sessionID: id,
            state: state,
            since: Date(timeIntervalSince1970: since),
            cwd: raw["cwd"] as? String ?? "",
            pid: pid,
            updatedAt: Date(timeIntervalSince1970: updated))
    }
}

struct BarSegment: Equatable {
    let state: SessionState
    let count: Int
    let blinking: Bool
}

struct SessionRow: Equatable {
    let name: String
    let state: SessionState
    let elapsed: TimeInterval
    let overThreshold: Bool
}

struct DisplayOutput: Equatable {
    let segments: [BarSegment]
    let rows: [SessionRow]
    let soundsToPlay: [String]
}

func formatElapsed(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
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

    private var alertedKeys: Set<String> = []
    private var seenEntryKeys: Set<String> = []
    /// False until the first evaluate: sessions already waiting when the app
    /// launches are seeded silently instead of firing an entry-sound burst.
    private var primed = false

    func evaluate(_ snapshots: [SessionSnapshot], activePIDs: Set<Int32>,
                  now: Date, config: Config) -> DisplayOutput {
        let effective: [(snap: SessionSnapshot, state: SessionState)] = snapshots.map { s in
            if s.state == .permission, config.activityDetection, activePIDs.contains(s.pid) {
                return (s, .running)
            }
            return (s, s.state)
        }

        var sounds: [String] = []
        var blinkStates: Set<SessionState> = []
        var rows: [SessionRow] = []
        var currentKeys: Set<String> = []
        var waitingKeys: Set<String> = []

        for (s, state) in effective {
            let elapsed = now.timeIntervalSince(s.since)
            var over = false
            if state != .running {
                let key = "\(s.sessionID)|\(s.since.timeIntervalSince1970)|\(state.rawValue)"
                waitingKeys.insert(key)
                let enteredNow = seenEntryKeys.insert(key).inserted && primed
                let threshold = state == .permission ? config.permissionAlertSec
                                                     : config.idleAlertSec
                var thresholdFired = false
                if elapsed >= threshold {
                    over = true
                    if config.blink { blinkStates.insert(state) }
                    currentKeys.insert(key)
                    if alertedKeys.insert(key).inserted {
                        thresholdFired = true
                        sounds.append(state == .permission ? config.soundPermission
                                                           : config.soundIdle)
                    }
                }
                // Entry sound follows the threshold sound unless overridden,
                // and is suppressed when the threshold alert fires this same
                // tick — one moment never produces two sounds.
                if enteredNow, !thresholdFired {
                    let name = state == .permission
                        ? (config.immediateSoundPermission ?? config.soundPermission)
                        : (config.immediateSoundIdle ?? config.soundIdle)
                    if !name.isEmpty { sounds.append(name) }
                }
            }
            rows.append(SessionRow(name: (s.cwd as NSString).lastPathComponent,
                                   state: state, elapsed: elapsed, overThreshold: over))
        }
        alertedKeys.formIntersection(currentKeys)
        seenEntryKeys.formIntersection(waitingKeys)
        primed = true

        let order: [SessionState] = [.running, .permission, .idle]
        let segments = order.compactMap { st -> BarSegment? in
            let count = effective.filter { $0.state == st }.count
            return count == 0 ? nil
                : BarSegment(state: st, count: count, blinking: blinkStates.contains(st))
        }

        let priority: [SessionState: Int] = [.permission: 0, .idle: 1, .running: 2]
        let sortedRows = rows.sorted {
            (priority[$0.state]!, $0.name) < (priority[$1.state]!, $1.name)
        }
        return DisplayOutput(segments: segments, rows: sortedRows, soundsToPlay: sounds)
    }
}
