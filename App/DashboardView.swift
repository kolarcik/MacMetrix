import SwiftUI
import Charts

/// Larger window – handy when looking at the machine over VNC.
struct DashboardView: View {
    @EnvironmentObject var store: MonitorStore
    @State private var range: Range = .fiveMinutes

    enum Range: String, CaseIterable, Identifiable {
        case fiveMinutes = "5 min", hour = "1 hod"
        var id: String { rawValue }
    }

    private var data: [MetricsSnapshot] {
        range == .fiveMinutes ? store.history : store.minuteHistory + [store.current]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.hostName).font(.title2.bold())
                Text(store.chipName).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            HStack(spacing: 14) {
                ForEach(Metric.allCases) { m in
                    VStack(spacing: 6) {
                        RingGauge(value: m.fraction(store.current), color: m.color,
                                  label: m.valueText(store.current), lineWidth: 9)
                            .frame(width: 92, height: 92)
                        Label(m.title, systemImage: m.symbol).font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    chartCard(.cpu, subtitle: "usr \(Fmt.percent(store.current.cpuUser)) · sys \(Fmt.percent(store.current.cpuSystem)) · load \(Fmt.load(store.current.load))")
                    chartCard(.gpu, subtitle: store.current.gpuMemory.map { "paměť GPU \(Fmt.gb($0))" } ?? "")
                }
                GridRow {
                    chartCard(.ram, subtitle: "\(Fmt.gb(store.current.memUsed)) / \(Fmt.gb(store.current.memTotal)) · komprim. \(Fmt.gb(store.current.memCompressed)) · swap \(Fmt.gb(store.current.swapUsed))")
                    chartCard(.net, subtitle: "↓ \(Fmt.rate(store.current.netIn))   ↑ \(Fmt.rate(store.current.netOut))")
                }
                GridRow {
                    chartCard(.disk, subtitle: "\(Fmt.gb(store.current.diskUsed)) / \(Fmt.gb(store.current.diskTotal)) · čtení \(Fmt.rate(store.current.diskRead)) · zápis \(Fmt.rate(store.current.diskWrite))")
                        .gridCellColumns(2)
                }
            }

            if !store.current.cores.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Jádra CPU").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(store.current.cores.enumerated()), id: \.offset) { _, v in
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.blue.opacity(0.15))
                                RoundedRectangle(cornerRadius: 2).fill(loadColor(.blue, v))
                                    .frame(height: max(1, 36 * v))
                            }
                            .frame(height: 36)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 720)
    }

    private func chartCard(_ m: Metric, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(m.title, systemImage: m.symbol).font(.headline).foregroundStyle(m.color)
                Spacer()
                Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Sparkline(history: data, metric: m, showAxis: true)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
