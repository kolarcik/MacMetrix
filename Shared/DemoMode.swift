import AppKit

/// Ukázkový režim pro snímky obrazovky do README: místo názvu Macu, IP adres
/// a názvů procesů ukazuje obecné údaje. Hodnoty měření zůstávají skutečné.
///
///     open /Applications/MacMetrix.app --args -demoMode YES
enum DemoMode {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "demoMode") }

    static let hostName = "Mac mini"

    static let interfaces: [(name: String, address: String)] = [("en0", "192.168.1.20"), ("utun4", "10.8.0.2")]

    /// Obecné názvy procesů pro seznam nejaktivnějších procesů, v pořadí podle vytížení.
    static func processNames(cpu: Bool, ram: Bool, net: Bool) -> [String] {
        if cpu { return ["swift-frontend", "clang", "xcodebuild", "Xcode", "dotnet", "node", "WindowServer", "kernel_task"] }
        if ram { return ["Xcode", "Simulator", "dotnet", "swift-frontend", "Safari", "node", "WindowServer", "mds_stores"] }
        if net { return ["git-remote-http", "dotnet", "Safari", "xcodebuild", "node", "Screen Sharing", "mDNSResponder", "apsd"] }
        return ["xcodebuild", "swift-frontend", "clang", "ld", "dotnet", "git", "mds_stores", "node"]
    }

    /// Generic process names for the Resource Monitor, assigned by pid.
    static let resourceProcessNames = [
        "Xcode", "Simulator", "Safari", "swift-frontend", "clang", "node", "dotnet", "Finder", "Mail",
        "Terminal", "Preview", "Notes", "Music", "Calendar", "Photos", "Dock", "Spotlight", "git", "ssh",
        "sourcekit-lsp", "xcodebuild", "ld", "lldb-rpc-server", "zsh", "Safari Web Content", "Xcode Helper",
    ]

    /// Generic names for processes of root and system users.
    static let systemProcessNames = [
        "WindowServer", "launchd", "logd", "mds_stores", "mds", "coreaudiod", "cfprefsd", "trustd",
        "configd", "powerd", "syslogd", "notifyd", "distnoted", "bluetoothd", "locationd", "opendirectoryd",
        "runningboardd", "sandboxd", "securityd", "diskarbitrationd",
    ]

    private static let bundles = [
        "Xcode": "com.apple.dt.Xcode",
        "Simulator": "com.apple.iphonesimulator",
        "Safari": "com.apple.Safari",
        "Screen Sharing": "com.apple.ScreenSharing",
        "Finder": "com.apple.finder",
        "Mail": "com.apple.mail",
        "Terminal": "com.apple.Terminal",
        "Preview": "com.apple.Preview",
        "Notes": "com.apple.Notes",
        "Music": "com.apple.Music",
        "Calendar": "com.apple.iCal",
        "Photos": "com.apple.Photos",
    ]

    /// Ikona ukázkového procesu: aplikace podle názvu, jinak nic (použije se obecná ikona).
    static func icon(for name: String) -> NSImage? {
        guard let id = bundles[name], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
