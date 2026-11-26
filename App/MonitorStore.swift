import AppKit
import Combine
import WidgetKit
import ServiceManagement

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var current: MetricsSnapshot = .empty
    /// Fine-grained history for the popover / Resource Monitor (one point per sample).
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

    /// How often the widget gets fresh data (seconds).
    @Published var widgetInterval: TimeInterval {
        didSet { UserDefaults.standard.set(widgetInterval, forKey: "widgetInterval") }
    }

    let hostName = SystemSampler.hostName
    let chipName = SystemSampler.chipName
    private let historySeconds: TimeInterval = 300

    // Sampler and sensors are only touched on `samplingQueue` (IOKit / IOHID calls can take tens of ms).
    private let sampler = SystemSampler()
    private let temperatures = TemperatureSensors()
    private let samplingQueue = DispatchQueue(label: "MacMetrix.sampling", qos: .utility)
    private var sampling = false
    private var timer: Timer?
    private var pending: [MetricsSnapshot] = []
    private var lastWidgetPush = Date.distantPast
    /// Widget reloads cost the widget extension several % CPU, so skip them when nobody can see a widget:
    /// none is on the desktop, or the screen is locked.
    private var widgetsPlaced = true
    private var lastWidgetCheck = Date.distantPast
    private var screenLocked = false
    private var lockObservers: [NSObjectProtocol] = []

    init() {
        let saved = UserDefaults.standard.double(forKey: "sampleInterval")
        sampleInterval = saved > 0 ? saved : 1
        let savedWidget = UserDefaults.standard.double(forKey: "widgetInterval")
        widgetInterval = savedWidget > 0 ? savedWidget : 10
        minuteHistory = SharedStore.read()?.history.filter { $0.date > Date().addingTimeInterval(-3600) } ?? []
        let sampler = sampler
        // Prime CPU / network counters. Its rates are meaningless, but the battery reading isn't:
        // show it right away instead of an empty battery until the first real sample.
        samplingQueue.async { [weak self] in
            let battery = sampler.sample().battery
            DispatchQueue.main.async {
                guard let self, self.current.date == .distantPast, let battery else { return }
                self.current.battery = battery
            }
        }
        enableLaunchAtLoginOnFirstRun()
        observeScreenLock()
        startTimer()
    }

    private func observeScreenLock() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        screenLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let center = DistributedNotificationCenter.default()
        lockObservers = [
            center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screenLocked = true }
            },
            center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    // Push fresh data right after unlocking.
                    self?.screenLocked = false
                    self?.lastWidgetPush = .distantPast
                }
            },
        ]
    }

    /// Re-checks once a minute whether any MacMetrix widget is on the desktop.
    private func refreshWidgetsPlaced(now: Date) {
        guard now.timeIntervalSince(lastWidgetCheck) >= 60 else { return }
        lastWidgetCheck = now
        WidgetCenter.shared.getCurrentConfigurations { [weak self] result in
            let placed = (try? result.get()).map { !$0.isEmpty } ?? true
            Task { @MainActor in
                guard let self else { return }
                if placed && !self.widgetsPlaced { self.lastWidgetPush = .distantPast } // widget just added
                self.widgetsPlaced = placed
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleInBackground() }
        }
        t.tolerance = sampleInterval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Free space is cached for a minute; refresh it right away after the disk cleanup.
    func refreshDiskCapacity() {
        let sampler = sampler
        samplingQueue.async { sampler.invalidateDiskCapacity() }
    }

    private func sampleInBackground() {
        guard !sampling else { return } // previous sample still running
        sampling = true
        let sampler = sampler, temperatures = temperatures
        samplingQueue.async { [weak self] in
            var s = sampler.sample()
            (s.cpuTemp, s.cpuTempMax, s.ssdTemp) = temperatures.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampling = false
                self.publish(s)
            }
        }
    }

    private func publish(_ s: MetricsSnapshot) {
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

        // Hand data over to the widget: shortly after start, then every `widgetInterval`.
        refreshWidgetsPlaced(now: s.date)
        let sinceLast = s.date.timeIntervalSince(lastWidgetPush)
        guard widgetsPlaced, !screenLocked else { return }
        if sinceLast >= widgetInterval - 0.5 || (lastWidgetPush == .distantPast && history.count >= 3) {
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
