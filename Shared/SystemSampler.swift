import Foundation
import Darwin
import IOKit

/// One measurement of the whole machine.
struct MetricsSnapshot: Codable, Hashable {
    var date: Date
    /// Total CPU usage 0...1
    var cpu: Double
    var cpuUser: Double
    var cpuSystem: Double
    /// Per-core usage 0...1
    var cores: [Double]
    /// GPU "Device Utilization" 0...1, nil when not available
    var gpu: Double?
    /// Memory the GPU currently has in use (bytes), if reported
    var gpuMemory: UInt64?
    /// "Memory Used" as in Activity Monitor (app + wired + compressed)
    var memUsed: UInt64
    var memTotal: UInt64
    var memCompressed: UInt64
    var memWired: UInt64
    var swapUsed: UInt64
    /// Bytes per second over physical interfaces (en*)
    var netIn: Double
    var netOut: Double
    /// Root volume capacity (bytes)
    var diskUsed: UInt64
    var diskTotal: UInt64
    /// Bytes per second over all block storage devices
    var diskRead: Double
    var diskWrite: Double
    var load: [Double]

    var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    var diskFraction: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0 }

    static let empty = MetricsSnapshot(
        date: .distantPast, cpu: 0, cpuUser: 0, cpuSystem: 0, cores: [], gpu: nil, gpuMemory: nil,
        memUsed: 0, memTotal: ProcessInfo.processInfo.physicalMemory, memCompressed: 0, memWired: 0,
        swapUsed: 0, netIn: 0, netOut: 0, diskUsed: 0, diskTotal: 0, diskRead: 0, diskWrite: 0, load: [0, 0, 0])

    /// Average of several snapshots (used for per-minute history).
    static func average(_ items: [MetricsSnapshot]) -> MetricsSnapshot? {
        guard let last = items.last else { return nil }
        let n = Double(items.count)
        func avg(_ k: (MetricsSnapshot) -> Double) -> Double { items.reduce(0) { $0 + k($1) } / n }
        func avgU(_ k: (MetricsSnapshot) -> UInt64) -> UInt64 { UInt64(avg { Double(k($0)) }) }
        let gpus = items.compactMap(\.gpu)
        var s = last
        s.cpu = avg(\.cpu)
        s.cpuUser = avg(\.cpuUser)
        s.cpuSystem = avg(\.cpuSystem)
        s.cores = []
        s.gpu = gpus.isEmpty ? nil : gpus.reduce(0, +) / Double(gpus.count)
        s.memUsed = avgU(\.memUsed)
        s.memCompressed = avgU(\.memCompressed)
        s.memWired = avgU(\.memWired)
        s.swapUsed = avgU(\.swapUsed)
        s.netIn = avg(\.netIn)
        s.netOut = avg(\.netOut)
        s.diskRead = avg(\.diskRead)
        s.diskWrite = avg(\.diskWrite)
        return s
    }
}

/// Reads CPU, GPU, memory and network counters. CPU and network values are
/// computed as a difference against the previous call to `sample()`.
final class SystemSampler {
    private var prevTicks: [CPUTicks]?
    private var prevNet: (rx: UInt64, tx: UInt64, time: TimeInterval)?
    private var prevDisk: (read: UInt64, write: UInt64, time: TimeInterval)?

    init() {}

    func sample() -> MetricsSnapshot {
        let now = Date()

        // CPU
        var cpu = 0.0, user = 0.0, system = 0.0
        var cores: [Double] = []
        if let ticks = Self.cpuTicks() {
            if let prev = prevTicks, prev.count == ticks.count {
                var tUser: UInt64 = 0, tSys: UInt64 = 0, tTotal: UInt64 = 0
                for (a, b) in zip(prev, ticks) {
                    let d = b.delta(from: a)
                    tUser += d.user + d.nice
                    tSys += d.system
                    tTotal += d.total
                    cores.append(d.total > 0 ? Double(d.user + d.nice + d.system) / Double(d.total) : 0)
                }
                if tTotal > 0 {
                    user = Double(tUser) / Double(tTotal)
                    system = Double(tSys) / Double(tTotal)
                    cpu = user + system
                }
            }
            prevTicks = ticks
        }

        // Network
        var netIn = 0.0, netOut = 0.0
        if let net = Self.networkBytes() {
            let t = ProcessInfo.processInfo.systemUptime
            if let p = prevNet, t > p.time, net.rx >= p.rx, net.tx >= p.tx {
                netIn = Double(net.rx - p.rx) / (t - p.time)
                netOut = Double(net.tx - p.tx) / (t - p.time)
            }
            prevNet = (net.rx, net.tx, t)
        }

        // Disk I/O
        var diskRead = 0.0, diskWrite = 0.0
        if let io = Self.diskIOBytes() {
            let t = ProcessInfo.processInfo.systemUptime
            if let p = prevDisk, t > p.time, io.read >= p.read, io.write >= p.write {
                diskRead = Double(io.read - p.read) / (t - p.time)
                diskWrite = Double(io.write - p.write) / (t - p.time)
            }
            prevDisk = (io.read, io.write, t)
        }
        let disk = Self.diskCapacity()

        let mem = Self.memory()
        let gpu = Self.gpu()

        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)

        return MetricsSnapshot(
            date: now, cpu: min(cpu, 1), cpuUser: user, cpuSystem: system, cores: cores,
            gpu: gpu.utilization, gpuMemory: gpu.memory,
            memUsed: mem.used, memTotal: mem.total, memCompressed: mem.compressed, memWired: mem.wired,
            swapUsed: mem.swap, netIn: netIn, netOut: netOut,
            diskUsed: disk.used, diskTotal: disk.total, diskRead: diskRead, diskWrite: diskWrite, load: load)
    }

    /// Takes two samples `interval` seconds apart so CPU / network deltas are meaningful.
    static func oneShot(interval: TimeInterval = 1.0) -> MetricsSnapshot {
        let s = SystemSampler()
        _ = s.sample()
        Thread.sleep(forTimeInterval: interval)
        return s.sample()
    }

    // MARK: - CPU

    struct CPUTicks {
        var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
        func delta(from o: CPUTicks) -> (user: UInt64, system: UInt64, nice: UInt64, total: UInt64) {
            // Counters are 32-bit and can wrap; use wrapping subtraction.
            let u = UInt64(UInt32(truncatingIfNeeded: user &- o.user))
            let s = UInt64(UInt32(truncatingIfNeeded: system &- o.system))
            let i = UInt64(UInt32(truncatingIfNeeded: idle &- o.idle))
            let n = UInt64(UInt32(truncatingIfNeeded: nice &- o.nice))
            return (u, s, n, u + s + i + n)
        }
    }

    static func cpuTicks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var result: [CPUTicks] = []
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            func v(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            result.append(CPUTicks(user: v(CPU_STATE_USER), system: v(CPU_STATE_SYSTEM),
                                   idle: v(CPU_STATE_IDLE), nice: v(CPU_STATE_NICE)))
        }
        return result
    }

    // MARK: - Memory

    static func memory() -> (used: UInt64, total: UInt64, compressed: UInt64, wired: UInt64, swap: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) != 0 { swap = xsw_usage() }

        guard kr == KERN_SUCCESS else { return (0, total, 0, 0, swap.xsu_used) }
        let page = UInt64(getpagesize())
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        return (min(app + wired + compressed, total), total, compressed, wired, swap.xsu_used)
    }

    // MARK: - Network

    /// Sums 64-bit byte counters of physical interfaces (en*). Loopback, VPN tunnels
    /// and VM bridges are skipped so traffic is not counted twice.
    static func networkBytes() -> (rx: UInt64, tx: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, u_int(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, u_int(mib.count), &buffer, &len, nil, 0) == 0 else { return nil }

        var rx: UInt64 = 0, tx: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                guard msgLen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(h2.ifm_index), &nameBuf) != nil {
                        let name = String(cString: nameBuf)
                        if name.hasPrefix("en") {
                            rx &+= h2.ifm_data.ifi_ibytes
                            tx &+= h2.ifm_data.ifi_obytes
                        }
                    }
                }
                offset += msgLen
            }
        }
        return (rx, tx)
    }

    // MARK: - Disk

    /// Capacity of the startup volume. "Free" includes purgeable space, like Finder shows it.
    static func diskCapacity() -> (used: UInt64, total: UInt64) {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, total > 0 else { return (0, 0) }
        let free = UInt64(max(v.volumeAvailableCapacityForImportantUsage ?? 0, 0))
        let t = UInt64(total)
        return (t > free ? t - free : 0, t)
    }

    /// Cumulative bytes read / written by all block storage drivers.
    static func diskIOBytes() -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0, found = false
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let cf = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue(),
                  let stats = cf as? [String: Any] else { continue }
            found = true
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return found ? (read, write) : nil
    }

    // MARK: - GPU

    /// Reads `PerformanceStatistics` of every IOAccelerator (works on Apple Silicon and Intel/AMD).
    static func gpu() -> (utilization: Double?, memory: UInt64?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return (nil, nil)
        }
        defer { IOObjectRelease(iterator) }

        var utilization: Double?
        var memory: UInt64?
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let cf = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue(),
                  let stats = cf as? [String: Any] else { continue }

            let keys = ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"]
            if let value = keys.lazy.compactMap({ (stats[$0] as? NSNumber)?.doubleValue }).first {
                utilization = max(utilization ?? 0, min(value / 100, 1))
            }
            if let mem = (stats["In use system memory"] as? NSNumber)?.uint64Value
                ?? (stats["vramUsedBytes"] as? NSNumber)?.uint64Value {
                memory = (memory ?? 0) + mem
            }
        }
        return (utilization, memory)
    }

    // MARK: - Static info

    static var chipName: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static var hostName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}
