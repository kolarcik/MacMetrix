import Darwin
import Foundation
import IOKit

/// A physical (or disk image) block device with its throughput, like Windows' Disk tab.
struct PhysicalDisk: Identifiable, Hashable {
    var id: String { bsdName }
    var bsdName: String
    var name: String
    var connection: Connection
    var size: UInt64
    var readRate: Double
    var writeRate: Double
    var readOps: Double
    var writeOps: Double
    /// Share of the interval the disk was serving requests (sum of read + write time), 0...1.
    /// Fast SSDs serve several requests at once, so it is capped at 100 %.
    var activeTime: Double
    /// Average time per operation in milliseconds; nil without operations.
    var latency: Double?
    var total: Double { readRate + writeRate }
    var latencySort: Double { latency ?? -1 }
    /// Shown and sorted in the table.
    var connectionName: String { connection.title }

    /// How the disk is attached: internal, external, a disk image… `other` carries IOKit's
    /// interconnect name ("USB", "Thunderbolt"), which is shown as is.
    enum Connection: Hashable {
        case `internal`, external, removable, diskImage, unknown
        case other(String)

        var title: String {
            switch self {
            case .internal: String(localized: "Interní")
            case .external: String(localized: "Externí")
            case .removable: String(localized: "Vyjímatelný")
            case .diskImage: String(localized: "Obraz disku")
            case .unknown: ""
            case .other(let name): name
            }
        }
    }
}

/// A mounted volume with its capacity.
struct VolumeInfo: Identifiable, Hashable {
    var id: String { mountPoint }
    var name: String
    var mountPoint: String
    /// BSD device ("disk3s1"), or the server for network volumes.
    var device: String
    var format: String
    var total: UInt64
    var free: UInt64
    var isLocal: Bool
    var isRemovable: Bool
    var used: UInt64 { total > free ? total - free : 0 }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// Reads block storage statistics from IOKit and the mounted volumes. Keeps the previous counters,
/// so it is only used from one queue (the Resource Monitor's sampler).
final class DiskSampler {
    private struct Counters { var bytesR, bytesW, opsR, opsW, timeR, timeW: UInt64 }
    private var prev: (counters: [String: Counters], time: TimeInterval)?
    private var volumesCache: (list: [VolumeInfo], time: TimeInterval)?

    func disks() -> [PhysicalDisk] {
        let now = ProcessInfo.processInfo.systemUptime
        var result: [PhysicalDisk] = []
        var counters: [String: Counters] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            guard let stats = Self.property(driver, "Statistics") as? [String: Any],
                  let media = Self.wholeMedia(of: driver) else { continue } // empty card reader etc.
            let c = Counters(bytesR: Self.u64(stats["Bytes (Read)"]), bytesW: Self.u64(stats["Bytes (Write)"]),
                             opsR: Self.u64(stats["Operations (Read)"]), opsW: Self.u64(stats["Operations (Write)"]),
                             timeR: Self.u64(stats["Total Time (Read)"]), timeW: Self.u64(stats["Total Time (Write)"]))
            counters[media.bsd] = c
            var disk = PhysicalDisk(bsdName: media.bsd, name: media.name, connection: Self.connection(driver, media: media),
                                    size: media.size, readRate: 0, writeRate: 0, readOps: 0, writeOps: 0,
                                    activeTime: 0, latency: nil)
            if let prev, let p = prev.counters[media.bsd], now > prev.time {
                let dt = now - prev.time
                func d(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double(a - b) : 0 }
                disk.readRate = d(c.bytesR, p.bytesR) / dt
                disk.writeRate = d(c.bytesW, p.bytesW) / dt
                disk.readOps = d(c.opsR, p.opsR) / dt
                disk.writeOps = d(c.opsW, p.opsW) / dt
                let busy = d(c.timeR, p.timeR) + d(c.timeW, p.timeW) // nanoseconds
                disk.activeTime = min(busy / (dt * 1e9), 1)
                let ops = d(c.opsR, p.opsR) + d(c.opsW, p.opsW)
                disk.latency = ops > 0 ? busy / ops / 1e6 : nil
            }
            result.append(disk)
        }
        prev = (counters, now)
        // Real disks first, then the disk images (simulator runtimes, mounted DMGs).
        return result.sorted {
            let (a, b) = ($0.connection == .diskImage, $1.connection == .diskImage)
            return a != b ? !a : $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending
        }
    }

    /// Mounted volumes the user can browse (no hidden system volumes). Refreshed every 5 s: capacities
    /// change slowly and network volumes can answer slowly.
    func volumes() -> [VolumeInfo] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cache = volumesCache, now - cache.time < 5 { return cache.list }
        // MNT_NOWAIT: never blocks on an unreachable network volume; capacities are the last known ones.
        // getmntinfo returns a buffer it reuses on the next call; only this sampler's queue calls it.
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        var list: [VolumeInfo] = []
        for s in UnsafeBufferPointer(start: buffer, count: Int(count)) {
            let flags = UInt32(s.f_flags)
            let mount = Self.string(s.f_mntonname)
            let type = Self.string(s.f_fstypename)
            guard flags & UInt32(MNT_DONTBROWSE) == 0, !["devfs", "autofs", "nullfs"].contains(type) else { continue }
            let local = flags & UInt32(MNT_LOCAL) != 0
            var from = Self.string(s.f_mntfromname)
            if from.hasPrefix("/dev/") { from.removeFirst(5) }
            let bsize = UInt64(s.f_bsize)
            var v = VolumeInfo(name: mount == "/" ? "Macintosh HD" : (mount as NSString).lastPathComponent,
                               mountPoint: mount, device: from, format: type.uppercased(),
                               total: UInt64(s.f_blocks) * bsize, free: UInt64(s.f_bavail) * bsize,
                               isLocal: local, isRemovable: false)
            if local {
                // Same numbers as Finder: available space includes what macOS can purge.
                let url = URL(fileURLWithPath: mount, isDirectory: true)
                if let r = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                                             .volumeAvailableCapacityForImportantUsageKey,
                                                             .volumeLocalizedFormatDescriptionKey,
                                                             .volumeIsRemovableKey, .volumeIsEjectableKey]) {
                    v.name = r.volumeLocalizedName ?? v.name
                    v.total = r.volumeTotalCapacity.map(UInt64.init) ?? v.total
                    v.free = r.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) } ?? v.free
                    v.format = r.volumeLocalizedFormatDescription ?? v.format
                    v.isRemovable = (r.volumeIsRemovable ?? false) || (r.volumeIsEjectable ?? false)
                }
            }
            list.append(v)
        }
        volumesCache = (list, now)
        return list
    }

    // MARK: - IOKit helpers

    private struct Media { var bsd: String; var name: String; var size: UInt64; var removable: Bool }

    /// The whole-disk IOMedia right below a storage driver.
    private static func wholeMedia(of driver: io_object_t) -> Media? {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &children) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "IOMedia") != 0,
                  let bsd = property(child, "BSD Name") as? String else { continue }
            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(child, &nameBuf)
            var name = String(cString: nameBuf)
            if name.hasSuffix(" Media") { name.removeLast(6) }
            return Media(bsd: bsd, name: name, size: u64(property(child, "Size")),
                         removable: (property(child, "Removable") as? Bool) ?? false)
        }
        return nil
    }

    private static func connection(_ driver: io_object_t, media: Media) -> PhysicalDisk.Connection {
        var parent: io_object_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS else { return .unknown }
        defer { IOObjectRelease(parent) }
        let proto = property(parent, "Protocol Characteristics") as? [String: Any]
        let interconnect = proto?["Physical Interconnect"] as? String ?? ""
        let location = proto?["Physical Interconnect Location"] as? String ?? ""
        if interconnect == "Virtual Interface" || media.name.contains("Disk Image") { return .diskImage }
        if location == "Internal" { return .internal }
        return interconnect.isEmpty ? (media.removable ? .removable : .external) : .other(interconnect)
    }

    private static func property(_ entry: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func u64(_ any: Any?) -> UInt64 { (any as? NSNumber)?.uint64Value ?? 0 }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
