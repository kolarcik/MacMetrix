import SwiftUI

/// Content of the status bar popover.
struct PopoverView: View {
    @EnvironmentObject var store: MonitorStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarStyle") private var style: MenuBarStyle = .iconValue
    @State private var showSettings = false
    @AppStorage(MenuBarMetrics.key) private var metricsRaw = MenuBarMetrics.all

    private func metricBinding(_ m: Metric) -> Binding<Bool> {
        Binding(
            get: { MenuBarMetrics.decode(metricsRaw).contains(m) },
            set: { on in
                var list = MenuBarMetrics.decode(metricsRaw).filter { $0 != m }
                if on { list.append(m) }
                metricsRaw = MenuBarMetrics.encode(Metric.allCases.filter(list.contains))
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(Metric.allCases) { m in
                MetricRow(metric: m, snapshot: store.current, history: store.history)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(store.hostName).font(.headline)
                Text(store.chipName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("Load \(Fmt.load(store.current.load))").font(.caption).monospacedDigit()
                Text("Uptime \(Fmt.uptime(ProcessInfo.processInfo.systemUptime))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "dashboard")
                } label: {
                    Label("Dashboard", systemImage: "rectangle.3.group")
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showSettings.toggle() }
                } label: {
                    Image(systemName: showSettings ? "gearshape.fill" : "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Nastavení")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Ukončit MacMetrix")
            }
            if showSettings { settings }
        }
    }

    /// Settings live inline in the popover: nested menus / popups are unreliable inside MenuBarExtra windows.
    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Spouštět po přihlášení", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
            if let err = store.loginItemError {
                Text(err).font(.caption2).foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Ukazatele ve stavové liště").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(Metric.allCases) { m in
                        Toggle(m.title, isOn: metricBinding(m))
                            .toggleStyle(.checkbox)
                    }
                }
                if MenuBarMetrics.decode(metricsRaw).isEmpty {
                    Text("Nic nevybráno – ve stavové liště bude jen ikona aplikace.").font(.caption2).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Vzhled ukazatelů").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $style) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Interval měření").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { store.sampleInterval },
                    set: { store.sampleInterval = $0 })) {
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("5 s").tag(5.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MetricRow: View {
    var metric: Metric
    var snapshot: MetricsSnapshot
    var history: [MetricsSnapshot]

    var body: some View {
        HStack(spacing: 10) {
            RingGauge(value: metric.fraction(snapshot), color: metric.color,
                      label: metric.ringLabel(snapshot), lineWidth: 5)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Label(metric.title, systemImage: metric.symbol).font(.subheadline.weight(.semibold))
                    Spacer()
                    if metric == .net {
                        InOutLegend(metric: metric, snapshot: snapshot)
                    } else {
                        Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Sparkline(history: history, metric: metric)
                    .frame(height: 28)
            }
        }
    }

    private var detail: String {
        switch metric {
        case .cpu:
            "usr \(Fmt.percent(snapshot.cpuUser)) · sys \(Fmt.percent(snapshot.cpuSystem)) · \(snapshot.cores.count) jader"
        case .gpu:
            snapshot.gpuMemory.map { "paměť \(Fmt.gb($0))" } ?? ""
        case .ram:
            "\(Fmt.gb(snapshot.memUsed)) / \(Fmt.gb(snapshot.memTotal))" + (snapshot.swapUsed > 0 ? " · swap \(Fmt.gb(snapshot.swapUsed))" : "")
        case .disk:
            "R \(Fmt.rate(snapshot.diskRead)) · W \(Fmt.rate(snapshot.diskWrite)) · \(Fmt.gb(snapshot.diskTotal - snapshot.diskUsed)) volno"
        case .net:
            "↓ \(Fmt.rate(snapshot.netIn))  ↑ \(Fmt.rate(snapshot.netOut))"
        }
    }
}
