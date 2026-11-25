import SwiftUI

/// Overview popover (shown from the app icon when no metric has its own status bar item).
struct PopoverView: View {
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(Metric.allCases) { m in
                MetricRow(metric: m, snapshot: store.current, history: store.history)
            }
            Divider()
            PopoverFooter()
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
}

/// Dashboard / settings / quit row shared by every popover. Dashboard and settings open in their own windows.
struct PopoverFooter: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            Button {
                open("dashboard")
            } label: {
                Label("Dashboard", systemImage: "rectangle.3.group")
            }
            Spacer()
            Button {
                open("about")
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("O aplikaci MacMetrix")
            Button {
                open("settings")
            } label: {
                Image(systemName: "gearshape")
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
    }

    private func open(_ id: String) {
        MenuBarWindows.closeAll()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
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
