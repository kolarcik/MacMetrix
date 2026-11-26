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
    var state: String
    var rateIn: Double
    var rateOut: Double
}

/// A file, folder or device a process holds open (Windows "Associated Handles").
struct OpenFile: Identifiable, Hashable {
    enum Kind: String { case file = "Soubor", folder = "Složka", device = "Zařízení", cwd = "Pracovní složka" }
    var id: String
    var pid: Int32
    var name: String
    /// File descriptor; -1 for the working directory.
    var fd: Int32
    var path: String
    var kind: Kind
    var mode: String
    var kindName: String { kind.rawValue }
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
/// - threads and disk I/O: `proc_pidinfo` / `proc_pid_rusage` (only processes of the current user)
/// - network: one `nettop` call gives per-process totals and every socket, including root processes
@MainActor
final class ResourceMonitor: ObservableObject {
    @Published private(set) var processes: [ProcessRow] = []
    @Published private(set) var connections: [NetConnection] = []
    @Published private(set) var listening: [ListeningPort] = []
    @Published private(set) var files: [OpenFile] = []
    /// Open files are only collected while the Soubory tab is shown.
    var collectFiles = false {
        didSet { if collectFiles && !oldValue { poll() } else if !collectFiles { files = [] } }
    }

    weak var window: NSWindow?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "MacMetrix.ResourceMonitor", qos: .utility)
    private let sampler = ResourceSampler()
    private var polling = false
    static let interval: TimeInterval = 2

    func start() {
        guard timer == nil else { return }
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
            let s = sampler.sample(files: collectFiles)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.polling = false
                guard self.timer != nil else { return }
                self.processes = s.processes
                self.connections = s.connections
                self.listening = s.listening
                self.files = self.collectFiles ? s.files : []
                // The Soubory tab opened while a sample without files was running: don't wait for the next tick.
                if self.collectFiles && !collectFiles { self.poll() }
            }
        }
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
                failed.append("\(ProcessMonitor.name(pid)) (\(pid)) – systémový proces")
                continue
            }
            if pid == getpid() {
                failed.append("MacMetrix (\(pid)) – sám sebe neukončí, použijte Ukončit MacMetrix")
                continue
            }
            if let expected = paths[pid], ResourceSampler.path(pid) != expected {
                failed.append("\((expected as NSString).lastPathComponent) (\(pid)) – mezitím skončil")
                continue
            }
            if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil {
                if force ? app.forceTerminate() : app.terminate() { continue }
            }
            if kill(pid, force ? SIGKILL : SIGTERM) != 0 {
                denied = denied || errno == EPERM
                let reason = errno == EPERM ? "patří jinému uživateli nebo systému" : String(cString: strerror(errno))
                failed.append("\(ProcessMonitor.name(pid)) (\(pid)) – \(reason)")
            }
        }
        guard !failed.isEmpty else { return nil }
        return "Nepodařilo se ukončit:\n" + failed.joined(separator: "\n")
            + (denied ? "\n\nMacMetrix běží bez oprávnění správce, takže takové procesy ukončit nemůže." : "")
    }
}

/// Counters between polls. Only touched on the ResourceMonitor queue.
final class ResourceSampler: @unchecked Sendable {
    struct Sample {
        var processes: [ProcessRow]
        var connections: [NetConnection]
        var listening: [ListeningPort]
        var files: [OpenFile]
    }

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
            var task = proc_taskinfo()
            if proc_pidinfo(p.pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
                row.threads = Int(task.pti_threadnum)
            }
            var info = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(p.pid, RUSAGE_INFO_V4, $0) }
            }
            if r == 0 {
                row.footprint = Int64(info.ri_phys_footprint)
                row.maxFootprint = Int64(info.ri_lifetime_max_phys_footprint)
                pageins[p.pid] = info.ri_pageins
                row.pageins = 0
                if let prev = prevPageins[p.pid], dt > 0, info.ri_pageins >= prev {
                    row.pageins = Double(info.ri_pageins - prev) / dt
                }
                let c = (info.ri_diskio_bytesread, info.ri_diskio_byteswritten)
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
                                         state: Self.stateName(s.state), rateIn: 0, rateOut: 0)
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
                      files: collectFiles ? rows.flatMap { Self.openFiles($0.pid, name: $0.name) } : [])
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
        case "Established": "Navázáno"
        case "SynSent": "Navazuje se"
        case "SynReceived": "Přijímá se"
        case "TimeWait": "Čeká (TIME_WAIT)"
        case "CloseWait": "Zavírá se (CLOSE_WAIT)"
        case "FinWait1", "FinWait2": "Zavírá se"
        case "LastAck", "Closing": "Zavírá se"
        case "Closed": "Zavřeno"
        default: s
        }
    }

    // MARK: - Open files

    /// Working directory and every vnode the process has open. Only processes of the current user
    /// are readable; scanning all of them takes ~10–20 ms.
    static func openFiles(_ pid: Int32, name: String) -> [OpenFile] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var result: [OpenFile] = []
        var cwd = proc_vnodepathinfo()
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwd, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
            let path = cString(cwd.pvi_cdir.vip_path)
            if !path.isEmpty && path != "/" {
                result.append(OpenFile(id: "\(pid)|cwd", pid: pid, name: name, fd: -1, path: path, kind: .cwd, mode: ""))
            }
        }
        // Room for a few more descriptors opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard got > 0 else { return result }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vi = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi,
                                 Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
            let path = cString(vi.pvip.vip_path)
            // /dev/null is open in nearly every process and only adds noise.
            guard !path.isEmpty, path != "/dev/null" else { continue }
            let type = vi.pvip.vip_vi.vi_stat.vst_mode & S_IFMT
            let kind: OpenFile.Kind = type == S_IFDIR ? .folder : (type == S_IFCHR || type == S_IFBLK) ? .device : .file
            // Kernel FREAD = 1, FWRITE = 2 (not exported to user space).
            let flags = vi.pfi.fi_openflags
            let mode = flags & 3 == 3 ? "čtení i zápis" : flags & 2 != 0 ? "zápis" : "čtení"
            result.append(OpenFile(id: "\(pid)|\(fd.proc_fd)|\(path)", pid: pid, name: name, fd: fd.proc_fd, path: path,
                                   kind: kind, mode: mode))
        }
        return result
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
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
