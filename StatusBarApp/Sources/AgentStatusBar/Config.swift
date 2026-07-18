import Foundation

struct Config: Equatable {
    var permissionAlertSec: Double = 120
    var idleAlertSec: Double = 300
    var soundPermission: String = "Glass"
    var soundIdle: String = "Tink"
    var blink: Bool = true
    var activityDetection: Bool = true
    var activityCpuThresholdPct: Double = 3.0

    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/agent-status-bar/config.json")

    init() {}

    init(raw: [String: Any]) {
        if let v = raw["permission_alert_sec"] as? NSNumber { permissionAlertSec = v.doubleValue }
        if let v = raw["idle_alert_sec"] as? NSNumber { idleAlertSec = v.doubleValue }
        if let v = raw["sound_permission"] as? String { soundPermission = v }
        if let v = raw["sound_idle"] as? String { soundIdle = v }
        if let v = raw["blink"] as? Bool { blink = v }
        if let v = raw["activity_detection"] as? Bool { activityDetection = v }
        if let v = raw["activity_cpu_threshold_pct"] as? NSNumber { activityCpuThresholdPct = v.doubleValue }
    }

    static func load(from url: URL = defaultURL) -> Config {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Config() }
        return Config(raw: raw)
    }
}
