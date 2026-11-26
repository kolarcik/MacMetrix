import Foundation
import ServiceManagement

/// Registration of the read-only privileged helper (Settings → Monitor prostředků) and the XPC client
/// the Resource Monitor's sampler uses. The user approves the daemon once in
/// System Settings → General → Login Items; until then the app shows only what it can read itself.
@MainActor
final class PrivilegedHelper: ObservableObject {
    static let shared = PrivilegedHelper()

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var error: String?

    private let service = SMAppService.daemon(plistName: HelperConstants.plistName)

    private init() { refresh() }

    /// The launchd plist is in the app bundle. `SMAppService` reports a daemon that was never registered
    /// as `.notFound` too, so only a missing plist really means a broken installation.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperConstants.plistName)").path)
    }

    func refresh() {
        let s = service.status
        status = s == .notFound && isInstalled ? .notRegistered : s
        HelperClient.shared.enabled = status == .enabled
    }

    func setEnabled(_ on: Bool) {
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
                HelperClient.shared.reset()
            }
            error = nil
        } catch {
            // Not failures: registering an already approved daemon again, and "Operation not permitted",
            // which is how register() reports that the user still has to approve it in System Settings.
            let status = service.status
            if !(on && (status == .enabled || status == .requiresApproval)) { self.error = error.localizedDescription }
        }
        refresh()
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Synchronous XPC calls to the helper, made from the sampler's background queue.
final class HelperClient: @unchecked Sendable {
    static let shared = HelperClient()

    /// Set from the main actor when the daemon is approved; read on the sampler queue.
    var enabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue } }
    }

    private let lock = NSLock()
    private var _enabled = false
    private var connection: NSXPCConnection?

    func reset() {
        lock.withLock {
            connection?.invalidate()
            connection = nil
        }
    }

    func processStats() -> [Int32: ProcStats]? {
        guard let data = call({ $0.processStats(reply: $1) }),
              let list = try? JSONDecoder().decode([ProcStats].self, from: data) else { return nil }
        return Dictionary(list.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func openFiles() -> [RawOpenFile]? {
        guard let data = call({ $0.openFiles(reply: $1) }) else { return nil }
        return try? JSONDecoder().decode([RawOpenFile].self, from: data)
    }

    /// Waits at most 2 s, so a stuck helper only delays one sample.
    private func call(_ body: (MacMetrixHelperProtocol, @escaping (Data) -> Void) -> Void) -> Data? {
        guard enabled, let conn = openConnection() else { return nil }
        let done = DispatchSemaphore(value: 0)
        let box = NSLock()
        var result: Data?
        // An XPC error (helper not running, refused signature) ends the wait right away.
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in done.signal() }) as? MacMetrixHelperProtocol
        else { return nil }
        body(proxy) { data in
            box.withLock { result = data }
            done.signal()
        }
        guard done.wait(timeout: .now() + 2) == .success else { return nil }
        return box.withLock { result }
    }

    private func openConnection() -> NSXPCConnection? {
        lock.withLock {
            if let connection { return connection }
            let c = NSXPCConnection(machServiceName: HelperConstants.machService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: MacMetrixHelperProtocol.self)
            // Only talk to our own helper, never to something else registered under the name.
            guard let req = HelperConstants.requirement(for: HelperConstants.helperIdentifier) else { return nil }
            c.setCodeSigningRequirement(req)
            c.invalidationHandler = { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.connection = nil }
            }
            c.resume()
            connection = c
            return c
        }
    }
}
