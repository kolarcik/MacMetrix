import Foundation
import Security

/// Read-only privileged helper (launchd daemon running as root) that fills in what the app can't read
/// about other users' and system processes: threads, footprint, disk I/O and open files.
/// It never changes anything – there is no call that writes, signals or deletes.
enum HelperConstants {
    static let machService = "tech.synot.MacMetrix.Helper"
    static let plistName = "tech.synot.MacMetrix.Helper.plist"
    static let appIdentifier = "tech.synot.MacMetrix"
    static let helperIdentifier = "tech.synot.MacMetrix.Helper"
    /// Bump when the protocol changes; the app re-registers a helper reporting another version.
    static let version = 1

    /// Code signing requirement for the other side of the connection: the given identifier, signed by
    /// Apple-issued certificate of the same team as this binary. Nil when this binary isn't team-signed.
    static func requirement(for identifier: String) -> String? {
        guard let team = ownTeamID() else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    private static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

@objc protocol MacMetrixHelperProtocol {
    func version(reply: @escaping (Int) -> Void)
    /// JSON `[ProcStats]` for every process.
    func processStats(reply: @escaping (Data) -> Void)
    /// JSON `[RawOpenFile]` for every process.
    func openFiles(reply: @escaping (Data) -> Void)
}
