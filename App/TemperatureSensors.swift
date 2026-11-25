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
        let c = values(cpu)
        let s = values(ssd)
        return (c.isEmpty ? nil : c.reduce(0, +) / Double(c.count), c.max(), s.max())
    }

    private func values(_ services: [AnyObject]) -> [Double] {
        services.compactMap { s in
            guard let e = IOHIDServiceClientCopyEvent(s, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            let v = IOHIDEventGetFloatValue(e, Int32(Self.temperatureEvent << 16))
            return v > 0 && v < 150 ? v : nil
        }
    }
}
