import SwiftUI

/// Content of the status bar popover.
struct PopoverView: View {
    @EnvironmentObject var store: MonitorStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarStyle") private var style: MenuBarStyle = .bars

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
        HStack {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "dashboard")
            } label: {
                Label("Dashboard", systemImage: "rectangle.3.group")
            }
            Spacer()
            Menu {
                Toggle("Spouštět po přihlášení", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }))
                Picker("Ve stavové liště", selection: $style) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Interval měření", selection: Binding(
                    get: { store.sampleInterval },
                    set: { store.sampleInterval = $0 })) {
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("5 s").tag(5.0)
                }
                Divider()
                Button("Ukončit MacMetrix") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .overlay(alignment: .top) {
            if let err = store.loginItemError {
                Text(err).font(.caption2).foregroundStyle(.red).offset(y: -18)
            }
        }
    }
}

struct MetricRow: View {
    var metric: Metric
    var snapshot: MetricsSnapshot
    var history: [MetricsSnapshot]

    var body: some View {
        HStack(spacing: 10) {
            RingGauge(value: metric.fraction(snapshot), color: metric.color,
                      label: metric == .net ? "" : metric.valueText(snapshot), lineWidth: 5)
                .overlay { if metric == .net { Image(systemName: "arrow.up.arrow.down").font(.caption) } }
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Label(metric.title, systemImage: metric.symbol).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
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
