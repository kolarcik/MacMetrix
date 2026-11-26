import Foundation

// Private IOHIDEventSystem API – readable without root on Apple Silicon (same approach as Stats / iStat).
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

/// CPU die and SSD temperatures from Apple Silicon thermal sensors. Returns nil on Intel Macs.
final class TemperatureSensors {
    private static let temperatureEvent: Int64 = 15 // kIOHIDEventTypeTemperature
    private var client: AnyObject?
    private var cpu: [AnyObject] = []
    private var ssd: [AnyObject] = []
    /// Reading all sensors takes ~30 ms of IOHID calls; temperatures change slowly, so reuse a recent reading.
    private var last: (value: (cpu: Double?, cpuMax: Double?, ssd: Double?), time: TimeInterval)?
    private static let minInterval: TimeInterval = 5

    init() {
        guard let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        // Apple vendor usage page / temperature sensor usage.
        _ = IOHIDEventSystemClientSetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        client = c
        let services = (IOHIDEventSystemClientCopyServices(c)?.takeRetainedValue() as? [AnyObject]) ?? []
        var named: [(String, AnyObject)] = []
        for s in services {
            if let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String {
                named.append((name, s))
            }
        }
        // M2+ report per-die "PMU tdie*"; M1 uses "pACC/eACC MTR Temp Sensor*".
        cpu = named.filter { $0.0.hasPrefix("PMU tdie") }.map(\.1)
        if cpu.isEmpty { cpu = named.filter { $0.0.contains("ACC MTR Temp") }.map(\.1) }
        ssd = named.filter { $0.0.hasPrefix("NAND") }.map(\.1)
    }

    /// (average CPU, hottest CPU sensor, SSD) in °C.
    func read() -> (cpu: Double?, cpuMax: Double?, ssd: Double?) {
        let now = ProcessInfo.processInfo.systemUptime
        // Half a second of slack: the sampling timer has 10 % tolerance, a 5 s sample may come at 4.9 s.
        if let last, now - last.time < Self.minInterval - 0.5 { return last.value }
        let c = values(cpu)
        let s = values(ssd)
        let value = (c.isEmpty ? nil : c.reduce(0, +) / Double(c.count), c.max(), s.max())
        last = (value, now)
        return value
    }

    private func values(_ services: [AnyObject]) -> [Double] {
        services.compactMap { s in
            guard let e = IOHIDServiceClientCopyEvent(s, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            let v = IOHIDEventGetFloatValue(e, Int32(Self.temperatureEvent << 16))
            return v > 0 && v < 150 ? v : nil
        }
    }
}
