import Foundation

enum SessionState: String {
    case running, permission, idle
}

enum AgentType: String {
    case claude, antigravity

    /// Short tag shown in dropdown rows.
    var label: String {
        switch self {
        case .claude: return "claude"
        case .antigravity: return "agy"
        }
    }
}

struct SessionSnapshot: Equatable {
    let sessionID: String
    let state: SessionState
    let since: Date
    let cwd: String
    let pid: Int32
    let updatedAt: Date
    let agent: AgentType

    static let contractVersion = 1

    init(sessionID: String, state: SessionState, since: Date, cwd: String,
         pid: Int32, updatedAt: Date, agent: AgentType = .claude) {
        self.sessionID = sessionID
        self.state = state
        self.since = since
        self.cwd = cwd
        self.pid = pid
        self.updatedAt = updatedAt
        self.agent = agent
    }

    /// The state file carries no agent field; `agent` is injected by the
    /// loader from the source directory.
    static func decode(_ data: Data, agent: AgentType = .claude) -> SessionSnapshot? {
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
            updatedAt: Date(timeIntervalSince1970: updated),
            agent: agent)
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
    let agent: AgentType
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
                           now: Date) -> (live: [SessionSnapshot], stale: [SessionSnapshot]) {
        var live: [SessionSnapshot] = []
        var stale: [SessionSnapshot] = []
        for s in snapshots {
            if livePIDs.contains(s.pid), now.timeIntervalSince(s.updatedAt) < Self.staleAge {
                live.append(s)
            } else {
                stale.append(s)
            }
        }
        return (live, stale)
    }

    private var alertedKeys: Set<String> = []
    private var seenEntryKeys: Set<String> = []
    /// Session ids (`agent|id`) observed on a previous tick. A session's first
    /// appearance is recorded here but fires no entry sound, so launching a new
    /// session (SessionStart -> idle) and app restart are both silent.
    private var knownSessions: Set<String> = []
    /// Wall-clock time of the last sound this model emitted (entry or nag).
    /// Threshold nags fire only once `sound_cooldown_sec` has passed since it.
    private var lastSoundAt: Date?

    func evaluate(_ snapshots: [SessionSnapshot], activePIDs: Set<Int32>,
                  now: Date, config: Config) -> DisplayOutput {
        let effective: [(snap: SessionSnapshot, state: SessionState)] = snapshots.map { s in
            if s.state == .permission, config.activityDetection, activePIDs.contains(s.pid) {
                return (s, .running)
            }
            return (s, s.state)
        }

        var blinkStates: Set<SessionState> = []
        var rows: [SessionRow] = []
        var currentKeys: Set<String> = []
        var waitingKeys: Set<String> = []
        var currentSessions: Set<String> = []
        var entrySounds: [String] = []
        // (priority, key, sound): permission (0) is preferred over idle (1).
        var nagCandidates: [(priority: Int, key: String, sound: String)] = []

        for (s, state) in effective {
            let sessionKey = "\(s.agent.rawValue)|\(s.sessionID)"
            let firstSight = !knownSessions.contains(sessionKey)
            currentSessions.insert(sessionKey)

            let elapsed = now.timeIntervalSince(s.since)
            var over = false
            if state != .running {
                let key = "\(s.agent.rawValue)|\(s.sessionID)|\(s.since.timeIntervalSince1970)|\(state.rawValue)"
                waitingKeys.insert(key)
                let enteredNow = seenEntryKeys.insert(key).inserted && !firstSight
                let threshold = state == .permission ? config.permissionAlertSec
                                                     : config.idleAlertSec
                if elapsed >= threshold {
                    over = true
                    if config.blink { blinkStates.insert(state) }
                    currentKeys.insert(key)
                    if !alertedKeys.contains(key) {
                        nagCandidates.append((
                            priority: state == .permission ? 0 : 1,
                            key: key,
                            sound: state == .permission ? config.soundPermission
                                                        : config.soundIdle))
                    }
                }
                // Entry sound only when entering a waiting state below its
                // threshold; a session already over threshold is represented by
                // its nag, so one moment never produces two sounds.
                if enteredNow, !over {
                    let name = state == .permission
                        ? (config.immediateSoundPermission ?? config.soundPermission)
                        : (config.immediateSoundIdle ?? config.soundIdle)
                    if !name.isEmpty { entrySounds.append(name) }
                }
            }
            rows.append(SessionRow(name: (s.cwd as NSString).lastPathComponent,
                                   state: state, elapsed: elapsed, overThreshold: over,
                                   agent: s.agent))
        }

        // Entry sounds always play and mark the moment. Nags are gated so no
        // nag lands within `sound_cooldown_sec` of any prior sound; a gated nag
        // is deferred (not marked alerted) and retried on a later tick.
        var sounds: [String] = []
        for name in entrySounds {
            sounds.append(name)
            lastSoundAt = now
        }
        for cand in nagCandidates.sorted(by: { $0.priority < $1.priority }) {
            let clear = lastSoundAt.map {
                now.timeIntervalSince($0) >= config.soundCooldownSec
            } ?? true
            if clear {
                alertedKeys.insert(cand.key)
                sounds.append(cand.sound)
                lastSoundAt = now
            }
        }

        alertedKeys.formIntersection(currentKeys)
        seenEntryKeys.formIntersection(waitingKeys)
        knownSessions = currentSessions

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
