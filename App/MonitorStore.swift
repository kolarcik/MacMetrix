import Foundation
import Combine
import WidgetKit
import ServiceManagement

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var current: MetricsSnapshot = .empty
    /// Fine-grained history for the popover / dashboard (one point per sample).
    @Published private(set) var history: [MetricsSnapshot] = []
    /// Per-minute averages (last hour) – also shared with the widget.
    @Published private(set) var minuteHistory: [MetricsSnapshot] = []
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var loginItemError: String?

    var sampleInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(sampleInterval, forKey: "sampleInterval")
            startTimer()
        }
    }

    let hostName = SystemSampler.hostName
    let chipName = SystemSampler.chipName
    private let historySeconds: TimeInterval = 300

    private let sampler = SystemSampler()
    private var timer: Timer?
    private var pending: [MetricsSnapshot] = []
    private var lastWidgetPush = Date.distantPast

    init() {
        let saved = UserDefaults.standard.double(forKey: "sampleInterval")
        sampleInterval = saved > 0 ? saved : 1
        minuteHistory = SharedStore.read()?.history.filter { $0.date > Date().addingTimeInterval(-3600) } ?? []
        _ = sampler.sample() // prime CPU / network counters
        enableLaunchAtLoginOnFirstRun()
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = sampleInterval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let s = sampler.sample()
        current = s
        history.append(s)
        let cutoff = s.date.addingTimeInterval(-historySeconds)
        if let idx = history.firstIndex(where: { $0.date >= cutoff }), idx > 0 { history.removeFirst(idx) }

        pending.append(s)
        if let first = pending.first, s.date.timeIntervalSince(first.date) >= 60, let avg = MetricsSnapshot.average(pending) {
            minuteHistory.append(avg)
            if minuteHistory.count > SharedStore.historyLimit { minuteHistory.removeFirst(minuteHistory.count - SharedStore.historyLimit) }
            pending.removeAll()
        }

        // Hand data over to the widget: shortly after start, then once a minute.
        let sinceLast = s.date.timeIntervalSince(lastWidgetPush)
        if sinceLast >= 60 || (lastWidgetPush == .distantPast && history.count >= 3) {
            lastWidgetPush = s.date
            SharedStore.write(SharedState(host: hostName, latest: s, history: minuteHistory))
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Launch at login

    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didConfigureLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setLaunchAtLogin(true)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginItemError = "Povolte v Nastavení systému → Obecné → Položky při přihlášení."
        }
    }
}
