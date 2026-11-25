import Foundation

/// State the app hands over to the widget through the App Group container.
struct SharedState: Codable {
    var host: String
    var latest: MetricsSnapshot
    /// Per-minute averages, oldest first (max `SharedStore.historyLimit`).
    var history: [MetricsSnapshot]
}

enum SharedStore {
    static let historyLimit = 60

    /// Team-prefixed App Group ID, injected into Info.plist by the build (key `AppGroupID`).
    static var groupID: String? { Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String }

    private static var fileURL: URL? {
        guard let groupID,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        return dir.appendingPathComponent("state.json")
    }

    static func read() -> SharedState? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SharedState.self, from: data)
    }

    /// Diagnostics: the widget records each timeline request so the app can show when it last refreshed.
    static func noteWidgetReload(fromApp: Bool) {
        guard let groupID, let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return }
        let url = dir.appendingPathComponent("widget-reloads.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(fromApp ? "app" : "self")\n"
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text += line
        let lines = text.split(separator: "\n").suffix(200)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Time of the widget's most recent timeline request, if any.
    static func lastWidgetReload() -> Date? {
        guard let groupID, let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID),
              let text = try? String(contentsOf: dir.appendingPathComponent("widget-reloads.log"), encoding: .utf8),
              let last = text.split(separator: "\n").last?.split(separator: " ").first else { return nil }
        return ISO8601DateFormatter().date(from: String(last))
    }

    static func write(_ state: SharedState) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum Fmt {
    static func percent(_ v: Double?) -> String {
        guard let v else { return "–" }
        return "\(Int((v * 100).rounded()))%"
    }

    static func bytes(_ v: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var d = Double(v)
        var i = 0
        while d >= 1024, i < units.count - 1 { d /= 1024; i += 1 }
        return i == 0 ? "\(v) B" : String(format: d < 10 ? "%.2f %@" : d < 100 ? "%.1f %@" : "%.0f %@", d, units[i])
    }

    static func gb(_ v: UInt64) -> String {
        String(format: "%.1f GB", Double(v) / 1_073_741_824)
    }

    /// Short rate like "12.3 MB/s"
    static func rate(_ bytesPerSecond: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = max(bytesPerSecond, 0)
        var i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? "\(Int(v)) \(units[i])" : String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, units[i])
    }

    /// Compact rate for gauges, e.g. "1.2M", "340K"
    static func shortRate(_ bytesPerSecond: Double) -> String {
        let units = ["B", "K", "M", "G"]
        var v = max(bytesPerSecond, 0)
        var i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? "\(Int(v))\(units[i])" : String(format: v < 10 ? "%.1f%@" : "%.0f%@", v, units[i])
    }

    static func load(_ l: [Double]) -> String {
        l.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: "  ")
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        return d > 0 ? "\(d) d \(h) h" : "\(h) h \(m) min"
    }
}
