import SwiftUI
import Charts

/// Larger window – handy when looking at the machine over VNC.
struct DashboardView: View {
    @EnvironmentObject var store: MonitorStore
    /// Kept in defaults: the view is recreated whenever the window comes back on screen.
    @AppStorage("dashboardRange") private var range: Range = .fiveMinutes

    enum Range: String, CaseIterable, Identifiable {
        case fiveMinutes = "5 min", hour = "1 hod"
        var id: String { rawValue }
    }

    /// Chart data. The 5 minute view averages samples into 2 s buckets (150 points instead of 300
    /// at the default 1 s interval): it looks the same at this width and halves the work of
    /// redrawing five charts every second. Buckets follow the clock, so they don't shift as time passes.
    private var data: [MetricsSnapshot] {
        guard range == .fiveMinutes else { return store.minuteHistory + [store.current] }
        var result: [MetricsSnapshot] = []
        var bucket: [MetricsSnapshot] = []
        var key = Int.min
        for s in store.history {
            let k = Int(s.date.timeIntervalSinceReferenceDate / 2)
            if k != key, let avg = MetricsSnapshot.average(bucket) { result.append(avg); bucket.removeAll() }
            key = k
            bucket.append(s)
        }
        if let avg = MetricsSnapshot.average(bucket) { result.append(avg) }
        return result
    }

    var body: some View {
        let data = data
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
                                  label: m.ringLabel(store.current), lineWidth: 9)
                            .frame(width: 92, height: 92)
                        Label(m.title, systemImage: m.symbol).font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    chartCard(.cpu, data, subtitle: "usr \(Fmt.percent(store.current.cpuUser)) · sys \(Fmt.percent(store.current.cpuSystem)) · load \(Fmt.load(store.current.load))")
                    chartCard(.gpu, data, subtitle: store.current.gpuMemory.map { "paměť GPU \(Fmt.gb($0))" } ?? "")
                }
                GridRow {
                    chartCard(.ram, data, subtitle: "\(Fmt.gb(store.current.memUsed)) / \(Fmt.gb(store.current.memTotal)) · komprim. \(Fmt.gb(store.current.memCompressed)) · swap \(Fmt.gb(store.current.swapUsed))")
                    chartCard(.net, data, subtitle: "")
                }
                GridRow {
                    chartCard(.disk, data, subtitle: "\(Fmt.gb(store.current.diskUsed)) / \(Fmt.gb(store.current.diskTotal)) · čtení \(Fmt.rate(store.current.diskRead)) · zápis \(Fmt.rate(store.current.diskWrite))")
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

    private func chartCard(_ m: Metric, _ data: [MetricsSnapshot], subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(m.title, systemImage: m.symbol).font(.headline).foregroundStyle(m.color)
                Spacer()
                if m == .net {
                    InOutLegend(metric: m, snapshot: store.current, font: .callout)
                } else {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
            Sparkline(history: data, metric: m, showAxis: true)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
