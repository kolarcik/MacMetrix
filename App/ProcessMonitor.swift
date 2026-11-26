import AppKit
import Darwin
import UniformTypeIdentifiers

/// One row of the "most active processes" list.
struct ProcessUsage: Identifiable, Hashable {
    var pid: Int32
    var name: String
    /// CPU: percent of one core; RAM: bytes; Disk / Network: bytes per second (IN/read + OUT/write).
    var value: Double
    var secondary: Double = 0
    var id: Int32 { pid }
}

/// Samples per-process usage for one metric while its popover is open.
/// - CPU / RAM: `ps` (setuid, sees all processes)
/// - Disk: `proc_pid_rusage` deltas (only processes of the current user are readable)
/// - Network: `nettop` cumulative bytes, delta between polls
@MainActor
final class ProcessMonitor: ObservableObject {
    @Published private(set) var top: [ProcessUsage] = []
    @Published private(set) var interfaces: [(name: String, address: String)] = []

    let metric: Metric
    /// Popover window hosting the list. Closing it from code (opening another window) doesn't
    /// always call onDisappear, so polling also pauses whenever the window isn't visible.
    weak var window: NSWindow?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "MacMetrix.ProcessMonitor", qos: .utility)
    private var prev: (counters: [Int32: (UInt64, UInt64)], time: TimeInterval)?
    private static let limit = 8

    init(metric: Metric) { self.metric = metric }

    var isSupported: Bool { metric != .gpu }

    func start() {
        guard isSupported, timer == nil else { return }
        poll()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            Task { @MainActor in
                guard let self, self.window?.isVisible ?? true else { return }
                self.poll()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        prev = nil
    }

    private func poll() {
        let metric = metric
        let prev = prev
        queue.async {
            var result: [ProcessUsage] = []
            var counters: [Int32: (UInt64, UInt64)] = [:]
            var names: [Int32: String] = [:]
            var interfaces: [(String, String)] = []
            let now = ProcessInfo.processInfo.systemUptime
            switch metric {
            case .cpu, .battery: // battery: CPU-heavy processes drain it the most
                result = Self.ps(column: "pcpu").map { ProcessUsage(pid: $0.pid, name: $0.name, value: $0.value) }
            case .ram:
                result = Self.ps(column: "rss").map { ProcessUsage(pid: $0.pid, name: $0.name, value: $0.value * 1024) }
            case .disk:
                counters = Self.diskCounters()
            case .net:
                (counters, names) = Self.netCounters()
                interfaces = SystemSampler.interfaceAddresses()
            case .gpu:
                break
            }
            if metric == .disk || metric == .net, let prev, now > prev.time {
                let dt = now - prev.time
                result = counters.compactMap { pid, c in
                    guard let p = prev.counters[pid], c.0 >= p.0, c.1 >= p.1 else { return nil }
                    let a = Double(c.0 - p.0) / dt, b = Double(c.1 - p.1) / dt
                    return a + b > 0 ? ProcessUsage(pid: pid, name: names[pid] ?? Self.name(pid), value: a, secondary: b) : nil
                }
            }
            var sorted = Array(result.sorted { $0.value + $0.secondary > $1.value + $1.secondary }.prefix(Self.limit))
            if DemoMode.isOn {
                let names = DemoMode.processNames(cpu: metric == .cpu || metric == .battery, ram: metric == .ram, net: metric == .net)
                sorted = sorted.enumerated().map { i, p in
                    ProcessUsage(pid: Int32(-1 - i), name: names[i % names.count], value: p.value, secondary: p.secondary)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.timer != nil else { return }
                self.top = sorted
                if metric == .disk || metric == .net { self.prev = (counters, now) }
                if metric == .net { self.interfaces = interfaces }
            }
        }
    }

    // MARK: - Sources

    nonisolated private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `ps -Aco pid=,<column>=,comm=` → (pid, value, name)
    nonisolated private static func ps(column: String) -> [(pid: Int32, value: Double, name: String)] {
        let out = run("/bin/ps", ["-Aco", "pid=,\(column)=,comm="])
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let v = Double(parts[1].replacingOccurrences(of: ",", with: "."))
            else { return nil }
            return (pid, v, String(parts[2]))
        }
    }

    /// Cumulative network bytes (in, out) per pid from `nettop` (-n: no DNS lookups, returns instantly).
    /// Names come from nettop too (proc_name can't read root processes). nettop truncates them to 15 chars.
    nonisolated private static func netCounters() -> ([Int32: (UInt64, UInt64)], [Int32: String]) {
        let out = run("/usr/bin/nettop", ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"])
        var result: [Int32: (UInt64, UInt64)] = [:]
        var names: [Int32: String] = [:]
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3, let dot = cols[0].lastIndex(of: "."),
                  let pid = Int32(cols[0][cols[0].index(after: dot)...]),
                  let i = UInt64(cols[1]), let o = UInt64(cols[2]) else { continue }
            result[pid] = (i, o)
            var name = Self.name(pid)
            if name.hasPrefix("pid ") { name = String(cols[0][..<dot]) }
            names[pid] = name
        }
        return (result, names)
    }

    /// Cumulative disk bytes (read, written) per pid. Other users' processes are not readable.
    nonisolated private static func diskCounters() -> [Int32: (UInt64, UInt64)] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var result: [Int32: (UInt64, UInt64)] = [:]
        for pid in pids.prefix(max(n, 0)) where pid > 0 {
            var info = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if r == 0 { result[pid] = (info.ri_diskio_bytesread, info.ri_diskio_byteswritten) }
        }
        return result
    }

    nonisolated private static func name(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        if proc_name(pid, &buf, UInt32(buf.count)) > 0 { return String(cString: buf) }
        return "pid \(pid)"
    }
}

/// App icon for a process (falls back to a generic executable icon).
@MainActor
enum ProcessIcon {
    /// Keyed by pid + name: pids get reused by unrelated processes.
    private static var cache: [String: NSImage] = [:]
    private static let generic: NSImage = NSWorkspace.shared.icon(for: .unixExecutable)

    static func image(_ pid: Int32, name: String) -> NSImage {
        let key = "\(pid)|\(name)"
        if let img = cache[key] { return img }
        let img = (pid < 0 ? DemoMode.icon(for: name) : NSRunningApplication(processIdentifier: pid)?.icon) ?? generic
        if cache.count > 500 { cache.removeAll() }
        cache[key] = img
        return img
    }
}
