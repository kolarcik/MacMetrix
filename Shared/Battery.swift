import Foundation
import IOKit

/// Internal battery of a MacBook, read from the `AppleSmartBattery` IORegistry entry.
/// Macs without a battery (Mac mini, Mac Studio, iMac) report nothing and the battery metric is hidden.
enum Battery {
    struct Reading: Codable, Hashable {
        /// 0...1
        var level: Double
        var charging: Bool
        /// Power adapter connected
        var onAC: Bool
        var fullyCharged: Bool
        /// Minutes to empty (on battery) or to full (charging); nil while macOS is still estimating
        var minutesRemaining: Int?
        var cycles: Int?
        /// Full charge capacity relative to the design capacity, 0...1
        var health: Double?
        /// °C
        var temperature: Double?
        /// Watts flowing into (+) or out of (−) the battery
        var batteryPower: Double?
        /// Watts the whole Mac draws right now (Apple Silicon telemetry), if reported
        var systemPower: Double?
        /// Rated watts of the connected power adapter
        var adapterWatts: Int?
    }

    private static let service: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))

    /// True on Macs with an internal battery.
    static let isPresent: Bool = {
        guard service != 0 else { return false }
        return (property("BatteryInstalled") as? Bool) ?? false
    }()

    private static func property(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func int(_ key: String) -> Int? { (property(key) as? NSNumber)?.intValue }

    static func read() -> Reading? {
        guard isPresent, let current = int("CurrentCapacity"), let max = int("MaxCapacity"), max > 0 else { return nil }
        let charging = (property("IsCharging") as? Bool) ?? false
        let onAC = (property("ExternalConnected") as? Bool) ?? false
        // 65535 means "unknown / still calculating".
        let minutes = charging ? int("AvgTimeToFull") : (onAC ? nil : int("AvgTimeToEmpty"))
        var health: Double?
        if let full = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity"), let design = int("DesignCapacity"), design > 0 {
            health = min(Double(full) / Double(design), 1)
        }
        var batteryPower: Double?
        if let mV = int("Voltage"), let mA = int("InstantAmperage") ?? int("Amperage") {
            batteryPower = Double(mV) * Double(mA) / 1_000_000
        }
        let telemetry = property("PowerTelemetryData") as? [String: Any]
        let systemLoad = (telemetry?["SystemLoad"] as? NSNumber)?.doubleValue
        let adapter = property("AdapterDetails") as? [String: Any]
        return Reading(
            level: min(Double(current) / Double(max), 1),
            charging: charging,
            onAC: onAC,
            fullyCharged: (property("FullyCharged") as? Bool) ?? false,
            minutesRemaining: minutes.flatMap { $0 > 0 && $0 < 65535 ? $0 : nil },
            cycles: int("CycleCount"),
            health: health,
            temperature: int("Temperature").map { Double($0) / 100 },
            batteryPower: batteryPower,
            systemPower: systemLoad.flatMap { $0 > 0 ? $0 / 1000 : nil },
            adapterWatts: onAC ? (adapter?["Watts"] as? NSNumber)?.intValue : nil)
    }
}

extension Battery.Reading {
    var stateText: String {
        if charging { return "Nabíjí se" }
        if onAC { return fullyCharged ? "Nabito" : "Připojeno, nenabíjí" }
        return "Na baterii"
    }

    /// "2:15" – hours and minutes left to empty or to full.
    var remainingText: String? {
        minutesRemaining.map { "\($0 / 60):\(String(format: "%02d", $0 % 60))" }
    }

    /// State with the remaining time, e.g. "Na baterii · zbývá 2:15".
    var summary: String {
        guard let t = remainingText else { return stateText }
        return "\(stateText) · \(charging ? "do nabití" : "zbývá") \(t)"
    }
}
