import AppKit
import Darwin

/// One process in the Resource Monitor. Unknown values (other users' processes can't be read) are -1,
/// so the columns still sort: unknown ends up below zero.
struct ProcessRow: Identifiable, Hashable {
    var pid: Int32
    var ppid: Int32
    var name: String
    var user: String
    var path: String?
    /// Percent of one core, like Activity Monitor.
    var cpu: Double
    var threads: Int
    var memory: UInt64
    var diskRead: Double
    var diskWrite: Double
    var netIn: Double
    var netOut: Double
    /// Physical footprint ("Memory" in Activity Monitor) and its peak; -1 for other users' processes.
    var footprint: Int64 = -1
    var maxFootprint: Int64 = -1
    /// Pages read in from disk per second (≈ hard faults in Windows); -1 when unknown.
    var pageins: Double = -1
    var id: Int32 { pid }
    var net: Double { netIn + netOut }
    /// Read + write; -1 when unknown.
    var disk: Double { diskRead < 0 ? -1 : diskRead + diskWrite }
}

/// An established (or closing) TCP connection.
struct NetConnection: Identifiable, Hashable {
    var id: String
    var pid: Int32
    var name: String
    var proto: String
    var localAddress: String
    var localPort: Int
    var remoteAddress: String
    var remotePort: Int
    /// Localized state name, shown and sorted in the table.
    var state: String
    /// TCP state is Established (highlighted in the table).
    var isEstablished: Bool
    var rateIn: Double
    var rateOut: Double
}

/// A file, folder or device a process holds open (Windows "Associated Handles").
struct OpenFile: Identifiable, Hashable {
    enum Kind: String {
        case file = "Soubor", folder = "Složka", device = "Zařízení", cwd = "Pracovní složka"

        var title: String {
            switch self {
            case .file: String(localized: "Soubor")
            case .folder: String(localized: "Složka")
            case .device: String(localized: "Zařízení")
            case .cwd: String(localized: "Pracovní složka")
            }
        }
    }
    var id: String
    var pid: Int32
    var name: String
    /// File descriptor; -1 for the working directory.
    var fd: Int32
    var path: String
    var kind: Kind
    /// Localized access mode ("čtení", "zápis"…).
    var mode: String
    var kindName: String { kind.title }
}

/// A TCP port in the Listen state, or a bound UDP port. IPv4 and IPv6 sockets of one process
/// on the same port are merged into one row.
struct ListeningPort: Identifiable, Hashable {
    var id: String
    var pid: Int32
    var name: String
    var proto: String
    var port: Int
    var addresses: String
}

/// Samples every process, its network connections and listening ports while the Resource Monitor
/// window is open.
/// - processes, CPU, memory, owner: `ps` (sees all processes); full name via `proc_pidpath`
/// - threads, footprint, disk I/O, open files: `ProcReader` – processes of the current user directly,
///   all others through the read-only privileged helper when the user approved it
/// - network: one `nettop` call gives per-process totals and every socket, including root processes
@MainActor
final class ResourceMonitor: ObservableObject {
    @Published private(set) var processes: [ProcessRow] = []
    @Published private(set) var connections: [NetConnection] = []
    @Published private(set) var listening: [ListeningPort] = []
    @Published private(set) var files: [OpenFile] = []
    @Published private(set) var disks: [PhysicalDisk] = []
    @Published private(set) var volumes: [VolumeInfo] = []
    /// The privileged helper answered the last sample: system processes have full details.
    @Published private(set) var helperActive = false
    /// Open files are only collected while the Soubory tab is shown.
    var collectFiles = false {
        didSet { if collectFiles && !oldValue { poll() } else if !collectFiles { files = [] } }
    }

    /// One point of a process's history.
    struct ProcSample {
        var date: Date
        /// Percent of one core.
        var cpu: Double
        /// Footprint, or resident memory where the footprint can't be read.
        var memory: Double
        /// Bytes per second read + written; -1 when unknown.
        var disk: Double
        var net: Double
    }

    /// Recent history of every process, for the graphs of the selected one. Not published: it changes
    /// together with `processes`, which already redraws the views.
    private(set) var history: [Int32: [ProcSample]] = [:]
    static let historySeconds: TimeInterval = 300

    weak var window: NSWindow?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "MacMetrix.ResourceMonitor", qos: .utility)
    private let sampler = ResourceSampler()
    private var polling = false
    static let interval: TimeInterval = 2

    func start() {
        guard timer == nil else { return }
        PrivilegedHelper.shared.refresh() // approved or switched off in System Settings meanwhile?
        poll()
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            Task { @MainActor in
                guard let self, self.window?.isVisible ?? true else { return }
                self.poll()
            }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard !polling, timer != nil else { return }
        polling = true
        let sampler = sampler, collectFiles = collectFiles
        queue.async {
            var s = sampler.sample(files: collectFiles)
            if DemoMode.isOn { s = s.disguised() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.polling = false
                guard self.timer != nil else { return }
                self.record(s.processes)
                self.processes = s.processes
                self.connections = s.connections
                self.listening = s.listening
                self.disks = s.disks
                if self.volumes != s.volumes { self.volumes = s.volumes }
                if self.helperActive != s.helperActive { self.helperActive = s.helperActive }
                self.files = self.collectFiles ? s.files : []
                // The Soubory tab opened while a sample without files was running: don't wait for the next tick.
                if self.collectFiles && !collectFiles { self.poll() }
            }
        }
    }

    private func record(_ rows: [ProcessRow]) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.historySeconds)
        var next: [Int32: [ProcSample]] = [:]
        next.reserveCapacity(rows.count)
        for r in rows {
            var list = history[r.pid] ?? []
            if let first = list.first, first.date < cutoff { list.removeAll { $0.date < cutoff } }
            list.append(ProcSample(date: now, cpu: r.cpu, memory: Double(r.footprint >= 0 ? UInt64(r.footprint) : r.memory),
                                   disk: r.diskRead < 0 ? -1 : r.diskRead + r.diskWrite, net: r.net))
            next[r.pid] = list
        }
        history = next // exited processes drop out
    }

    // MARK: - Ending processes

    /// Quits apps the way the Dock does (`terminate`), other processes with SIGTERM;
    /// `force` uses `forceTerminate` / SIGKILL. Returns an error message for processes that couldn't be ended.
    /// `paths` are the executables the user confirmed: a pid whose process exited and got reused
    /// by another program in the meantime is left alone.
    static func end(_ pids: [Int32], paths: [Int32: String], force: Bool) -> String? {
        var failed: [String] = []
        var denied = false
        for pid in pids {
            if pid <= 1 {
                failed.append(String(localized: "\(ProcessMonitor.name(pid)) (\(pid)) – systémový proces"))
                continue
            }
            if pid == getpid() {
                failed.append(String(localized: "MacMetrix (\(pid)) – sám sebe neukončí, použijte Ukončit MacMetrix"))
                continue
            }
            if let expected = paths[pid], ResourceSampler.path(pid) != expected {
                failed.append(String(localized: "\((expected as NSString).lastPathComponent) (\(pid)) – mezitím skončil"))
                continue
            }
            if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil {
                if force ? app.forceTerminate() : app.terminate() { continue }
            }
            if kill(pid, force ? SIGKILL : SIGTERM) != 0 {
                denied = denied || errno == EPERM
                let reason = errno == EPERM ? String(localized: "patří jinému uživateli nebo systému") : String(cString: strerror(errno))
                failed.append("\(ProcessMonitor.name(pid)) (\(pid)) – \(reason)")
            }
        }
        guard !failed.isEmpty else { return nil }
        return String(localized: "Nepodařilo se ukončit:") + "\n" + failed.joined(separator: "\n")
            + (denied ? "\n\n" + String(localized: "MacMetrix běží bez oprávnění správce, takže takové procesy ukončit nemůže.") : "")
    }
}

/// Counters between polls. Only touched on the ResourceMonitor queue.
final class ResourceSampler: @unchecked Sendable {
    struct Sample {
        var processes: [ProcessRow]
        var connections: [NetConnection]
        var listening: [ListeningPort]
        var files: [OpenFile]
        var helperActive: Bool
        var disks: [PhysicalDisk]
        var volumes: [VolumeInfo]
    }

    private let diskSampler = DiskSampler()

    private var prevTime: TimeInterval?
    private var prevDisk: [Int32: (UInt64, UInt64)] = [:]
    private var prevPageins: [Int32: UInt64] = [:]
    private var prevNet: [Int32: (UInt64, UInt64)] = [:]
    private var prevSockets: [String: (UInt64, UInt64)] = [:]
    /// pid → (ps comm, display name, path). Keyed by comm too, because pids get reused.
    private var names: [Int32: (comm: String, name: String, path: String?)] = [:]

    func sample(files collectFiles: Bool) -> Sample {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = prevTime.map { now - $0 } ?? 0
        let ps = Self.ps()
        let net = Self.nettop()
        // Other users' and system processes, when the privileged helper is approved.
        let helper = HelperClient.shared.processStats()

        var disk: [Int32: (UInt64, UInt64)] = [:]
        var pageins: [Int32: UInt64] = [:]
        var rows: [ProcessRow] = []
        rows.reserveCapacity(ps.count)
        var seen = Set<Int32>()
        for p in ps {
            seen.insert(p.pid)
            let (name, path) = displayName(p.pid, comm: p.comm)
            var row = ProcessRow(pid: p.pid, ppid: p.ppid, name: name, user: p.user, path: path, cpu: p.cpu,
                                 threads: -1, memory: p.rss, diskRead: -1, diskWrite: -1, netIn: 0, netOut: 0)
            if let st = ProcReader.stats(p.pid) ?? helper?[p.pid] {
                row.threads = st.threads
                row.footprint = Int64(st.footprint)
                row.maxFootprint = Int64(st.maxFootprint)
                pageins[p.pid] = st.pageins
                row.pageins = 0
                if let prev = prevPageins[p.pid], dt > 0, st.pageins >= prev {
                    row.pageins = Double(st.pageins - prev) / dt
                }
                let c = (st.diskRead, st.diskWrite)
                disk[p.pid] = c
                if let prev = prevDisk[p.pid], dt > 0 {
                    row.diskRead = c.0 >= prev.0 ? Double(c.0 - prev.0) / dt : 0
                    row.diskWrite = c.1 >= prev.1 ? Double(c.1 - prev.1) / dt : 0
                } else {
                    row.diskRead = 0
                    row.diskWrite = 0
                }
            }
            if let c = net.totals[p.pid], let prev = prevNet[p.pid], dt > 0 {
                row.netIn = c.0 >= prev.0 ? Double(c.0 - prev.0) / dt : 0
                row.netOut = c.1 >= prev.1 ? Double(c.1 - prev.1) / dt : 0
            }
            rows.append(row)
        }
        names = names.filter { seen.contains($0.key) }
        let nameOf = Dictionary(rows.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })

        var connections: [NetConnection] = []
        var ports: [String: ListeningPort] = [:]
        var sockets: [String: (UInt64, UInt64)] = [:]
        for s in net.sockets {
            let name = nameOf[s.pid] ?? s.name
            if s.isListening {
                let key = "\(s.pid)|\(s.proto)|\(s.local.port)"
                let family = s.family
                if var p = ports[key] {
                    if !p.addresses.contains(Self.listenAddress(s.local.host, family)) {
                        p.addresses += ", " + Self.listenAddress(s.local.host, family)
                    }
                    ports[key] = p
                } else {
                    ports[key] = ListeningPort(id: key, pid: s.pid, name: name, proto: s.proto, port: s.local.port,
                                               addresses: Self.listenAddress(s.local.host, family))
                }
            } else if s.proto == "TCP" {
                let id = "\(s.pid)|\(s.local.host):\(s.local.port)|\(s.remote.host):\(s.remote.port)"
                var conn = NetConnection(id: id, pid: s.pid, name: name, proto: s.family, localAddress: s.local.host,
                                         localPort: s.local.port, remoteAddress: s.remote.host, remotePort: s.remote.port,
                                         state: Self.stateName(s.state), isEstablished: s.state == "Established",
                                         rateIn: 0, rateOut: 0)
                sockets[id] = (s.bytesIn, s.bytesOut)
                if let prev = prevSockets[id], dt > 0 {
                    conn.rateIn = s.bytesIn >= prev.0 ? Double(s.bytesIn - prev.0) / dt : 0
                    conn.rateOut = s.bytesOut >= prev.1 ? Double(s.bytesOut - prev.1) / dt : 0
                }
                connections.append(conn)
            }
        }

        prevTime = now
        prevDisk = disk
        prevPageins = pageins
        prevNet = net.totals
        prevSockets = sockets
        return Sample(processes: rows, connections: connections,
                      listening: ports.values.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) },
                      files: collectFiles ? Self.openFiles(rows, nameOf: nameOf, viaHelper: helper != nil) : [],
                      helperActive: helper != nil, disks: diskSampler.disks(), volumes: diskSampler.volumes())
    }

    /// App bundle name for apps ("Microsoft Teams"), the executable's full name otherwise
    /// (`ps` and `nettop` cut names to 15–16 characters).
    /// Executable path of a running process, nil when it no longer exists.
    static func path(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    private func displayName(_ pid: Int32, comm: String) -> (String, String?) {
        if let cached = names[pid], cached.comm == comm { return (cached.name, cached.path) }
        var buf = [CChar](repeating: 0, count: 4096)
        var path: String?
        var name = comm
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let p = String(cString: buf)
            path = p
            if let range = p.range(of: ".app/Contents/MacOS/") {
                let bundle = p[..<range.lowerBound]
                let appName = bundle[(bundle.lastIndex(of: "/").map { bundle.index(after: $0) } ?? bundle.startIndex)...]
                let exe = (p as NSString).lastPathComponent
                // Helpers inside an app keep their own name ("Google Chrome Helper"), the main executable gets the app's.
                name = exe == appName || exe.count < 3 ? String(appName) : exe
            } else {
                name = (p as NSString).lastPathComponent
            }
        }
        names[pid] = (comm, name, path)
        return (name, path)
    }

    private static func listenAddress(_ host: String, _ family: String) -> String {
        host == "*" ? (family == "IPv6" ? "* (IPv6)" : "* (IPv4)") : host
    }

    private static func stateName(_ s: String) -> String {
        switch s {
        case "Established": String(localized: "Navázáno")
        case "SynSent": String(localized: "Navazuje se")
        case "SynReceived": String(localized: "Přijímá se")
        case "TimeWait": String(localized: "Čeká (TIME_WAIT)")
        case "CloseWait": String(localized: "Zavírá se (CLOSE_WAIT)")
        case "FinWait1", "FinWait2": String(localized: "Zavírá se")
        case "LastAck", "Closing": String(localized: "Zavírá se")
        case "Closed": String(localized: "Zavřeno")
        default: s
        }
    }

    // MARK: - Open files

    /// Open files of every process: all of them through the helper, otherwise those of the current user.
    private static func openFiles(_ rows: [ProcessRow], nameOf: [Int32: String], viaHelper: Bool) -> [OpenFile] {
        let raw = (viaHelper ? HelperClient.shared.openFiles() : nil) ?? rows.flatMap { ProcReader.openFiles($0.pid) }
        return raw.map { f in
            let kind: OpenFile.Kind = switch f.kind {
            case .file: .file
            case .folder: .folder
            case .device: .device
            case .cwd: .cwd
            }
            let mode = switch f.mode {
            case "rw": String(localized: "čtení i zápis")
            case "w": String(localized: "zápis")
            case "r": String(localized: "čtení")
            default: ""
            }
            return OpenFile(id: "\(f.pid)|\(f.fd)|\(f.path)", pid: f.pid, name: nameOf[f.pid] ?? "pid \(f.pid)",
                            fd: f.fd, path: f.path, kind: kind, mode: mode)
        }
    }

    // MARK: - ps

    private struct PsRow { var pid: Int32; var ppid: Int32; var user: String; var cpu: Double; var rss: UInt64; var comm: String }

    /// `ps -Aco pid=,ppid=,user=,pcpu=,rss=,comm=`
    private static func ps() -> [PsRow] {
        let out = ProcessMonitor.run("/bin/ps", ["-Aco", "pid=,ppid=,user=,pcpu=,rss=,comm="])
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard f.count == 6, let pid = Int32(f[0]), let ppid = Int32(f[1]),
                  let cpu = Double(f[3].replacingOccurrences(of: ",", with: ".")), let rss = UInt64(f[4]) else { return nil }
            return PsRow(pid: pid, ppid: ppid, user: String(f[2]), cpu: cpu, rss: rss * 1024, comm: String(f[5]))
        }
    }

    // MARK: - nettop

    struct Endpoint: Hashable { var host: String; var port: Int }

    struct Socket {
        var pid: Int32
        var name: String
        /// "TCP" / "UDP"
        var proto: String
        /// "IPv4" / "IPv6"
        var family: String
        var local: Endpoint
        var remote: Endpoint
        var state: String
        var bytesIn: UInt64
        var bytesOut: UInt64

        /// TCP in Listen, or UDP bound to a port without a peer.
        var isListening: Bool {
            guard local.port > 0 else { return false }
            return proto == "TCP" ? state == "Listen" : remote.port == 0
        }
    }

    /// One `nettop` snapshot: lines "name.pid,,in,out," for a process, followed by
    /// "tcp4 1.2.3.4:5<->6.7.8.9:10,State,in,out," for each of its sockets (IPv6 uses "." before the port).
    static func nettop() -> (totals: [Int32: (UInt64, UInt64)], sockets: [Socket]) {
        let out = ProcessMonitor.run("/usr/bin/nettop", ["-L", "1", "-n", "-x", "-J", "state,bytes_in,bytes_out"])
        var totals: [Int32: (UInt64, UInt64)] = [:]
        var sockets: [Socket] = []
        var current: (pid: Int32, name: String)?
        for line in out.split(separator: "\n").dropFirst() {
            // "<name>,<state>,<in>,<out>," – the name itself may contain commas ("Foo, Inc."), so the
            // columns are taken from the end and everything before them is the name.
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 5 else { continue }
            let n = cols.count
            let first = cols[..<(n - 4)].joined(separator: ",")[...]
            let state = cols[n - 4]
            let bytesIn = UInt64(cols[n - 3]) ?? 0, bytesOut = UInt64(cols[n - 2]) ?? 0
            if let space = first.firstIndex(of: " "), first.contains("<->") {
                guard let proc = current else { continue }
                let kind = first[..<space]
                let ends = first[first.index(after: space)...].components(separatedBy: "<->")
                guard ends.count == 2, kind.count == 4 else { continue }
                let v6 = kind.hasSuffix("6")
                sockets.append(Socket(pid: proc.pid, name: proc.name, proto: kind.hasPrefix("tcp") ? "TCP" : "UDP",
                                      family: v6 ? "IPv6" : "IPv4", local: endpoint(ends[0], v6: v6),
                                      remote: endpoint(ends[1], v6: v6), state: String(state),
                                      bytesIn: bytesIn, bytesOut: bytesOut))
            } else if let dot = first.lastIndex(of: "."), let pid = Int32(first[first.index(after: dot)...]) {
                current = (pid, String(first[..<dot]))
                totals[pid] = (bytesIn, bytesOut)
            } else {
                // A process line we can't read: its sockets must not end up under the previous process.
                current = nil
            }
        }
        return (totals, sockets)
    }

    /// "192.168.0.1:443", "*:*", "fe80::1%en0.443", "*.*" → host + port (0 = any).
    private static func endpoint(_ s: String, v6: Bool) -> Endpoint {
        guard let sep = s.lastIndex(of: v6 ? "." : ":") else { return Endpoint(host: s, port: 0) }
        return Endpoint(host: String(s[..<sep]), port: Int(s[s.index(after: sep)...]) ?? 0)
    }
}

// MARK: - Demo mode

extension ResourceSampler.Sample {
    /// Screenshot mode (`-demoMode YES`): generic process names, user, paths and addresses instead of
    /// the real ones. Measured values stay real; icons follow the generic names (see `ProcessIcon`).
    func disguised() -> Self {
        let home = NSHomeDirectory()
        let users = Dictionary(processes.map { ($0.pid, $0.user) }, uniquingKeysWith: { a, _ in a })
        func isSystem(_ pid: Int32) -> Bool { users[pid].map { $0 == "root" || $0.hasPrefix("_") } ?? true }
        func name(_ pid: Int32) -> String {
            let list = isSystem(pid) ? DemoMode.systemProcessNames : DemoMode.resourceProcessNames
            return list[Int(UInt32(bitPattern: pid) % UInt32(list.count))]
        }
        func pid(_ pid: Int32) -> Int32 { pid }
        func user(_ u: String) -> String { u == "root" || u.hasPrefix("_") ? u : "user" }
        func address(_ a: String, seed: Int32) -> String {
            if a == "*" || a.hasPrefix("127.") || a == "::1" { return a }
            if a.hasPrefix("192.168.") || a.hasPrefix("10.") || a.hasPrefix("fe80") { return a.contains(":") ? "fe80::1c2a" : "192.168.1.20" }
            let n = UInt32(bitPattern: seed)
            return "17.\(n % 200 + 20).\(n / 7 % 250).\(n / 13 % 250)"
        }
        var copy = self
        copy.processes = processes.map { r in
            var r = r
            r.name = name(r.pid)
            r.user = user(r.user)
            r.path = "/Applications/\(r.name).app"
            r.pid = pid(r.pid)
            r.ppid = pid(r.ppid)
            return r
        }
        copy.connections = connections.map { c in
            var c = c
            c.name = name(c.pid)
            c.localAddress = address(c.localAddress, seed: c.pid)
            c.remoteAddress = address(c.remoteAddress, seed: c.pid &+ Int32(c.remotePort))
            c.id = "\(c.pid)|\(c.id)"
            c.pid = pid(c.pid)
            return c
        }
        copy.listening = listening.map { p in
            var p = p
            p.name = name(p.pid)
            p.pid = pid(p.pid)
            return p
        }
        copy.files = files.map { f in
            var f = f
            f.name = name(f.pid)
            if f.path.hasPrefix(home) { f.path = "/Users/user" + f.path.dropFirst(home.count) }
            f.pid = pid(f.pid)
            return f
        }
        return copy
    }
}
