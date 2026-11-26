import Foundation

/// MacMetrix privileged helper: a launchd daemon (registered by the app with SMAppService) that answers
/// read-only questions about all processes over XPC. Only the MacMetrix app signed by the same team may connect.
final class HelperService: NSObject, MacMetrixHelperProtocol {
    func version(reply: @escaping (Int) -> Void) {
        Idle.touch()
        reply(HelperConstants.version)
    }

    func processStats(reply: @escaping (Data) -> Void) {
        Idle.touch()
        let stats = ProcReader.allPids().compactMap(ProcReader.stats)
        reply((try? JSONEncoder().encode(stats)) ?? Data())
    }

    func openFiles(reply: @escaping (Data) -> Void) {
        Idle.touch()
        let files = ProcReader.allPids().flatMap(ProcReader.openFiles)
        reply((try? JSONEncoder().encode(files)) ?? Data())
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let requirement = HelperConstants.requirement(for: HelperConstants.appIdentifier)

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Without our own team signature there is nothing to compare the caller with: refuse everyone.
        guard let requirement else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: MacMetrixHelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

/// The helper is only needed while the Resource Monitor window is open. It quits after two idle minutes;
/// launchd starts it again on the next request (and after an app update, the new binary).
enum Idle {
    private static let lock = NSLock()
    private static var last = Date()
    static func touch() { lock.withLock { last = Date() } }
    static func start() {
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            if lock.withLock({ Date().timeIntervalSince(last) }) > 120 { exit(0) }
        }
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machService)
listener.delegate = delegate
listener.resume()
Idle.start()
RunLoop.main.run()
