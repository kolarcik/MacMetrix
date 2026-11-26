import SwiftUI

/// Right-hand panel of the Resource Monitor, like the graphs in Windows: total CPU, history of every
/// core, memory, disk, network and GPU. Observes the store on its own, so the process tables next to it
/// don't redraw on every sample.
struct ResourceGraphs: View {
    @EnvironmentObject var store: MonitorStore
    /// Kept in defaults: the view is recreated whenever the window comes back on screen.
    @AppStorage("resourcesRange") private var range: Range = .oneMinute

    enum Range: String, CaseIterable, Identifiable {
        case oneMinute = "1 min", fiveMinutes = "5 min", hour = "1 hod"
        var id: String { rawValue }
        var seconds: TimeInterval { self == .oneMinute ? 60 : self == .fiveMinutes ? 300 : 3600 }
        var caption: String { self == .oneMinute ? "60 sekund" : self == .fiveMinutes ? "5 minut" : "60 minut (minutové průměry)" }
    }

    /// Chart data. One minute shows raw samples; five minutes averages them into 2 s buckets (150 points
    /// instead of 300 at the default 1 s interval), so redrawing a dozen charts every second stays cheap.
    /// Buckets follow the clock, so they don't shift as time passes.
    private var data: [MetricsSnapshot] {
        switch range {
        case .oneMinute:
            let cutoff = store.current.date.addingTimeInterval(-60)
            return store.history.filter { $0.date >= cutoff }
        case .hour:
            // Right after a minute closes, its average carries the current sample's date: skip the duplicate.
            let newer = store.minuteHistory.last.map { store.current.date > $0.date } ?? true
            return newer ? store.minuteHistory + [store.current] : store.minuteHistory
        case .fiveMinutes:
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
    }

    var body: some View {
        let data = data
        let s = store.current
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                card(.cpu, data, value: Fmt.percent(s.cpu),
                     subtitle: "usr \(Fmt.percent(s.cpuUser)) · sys \(Fmt.percent(s.cpuSystem)) · load \(Fmt.load(s.load))")
                cores(data)
                card(.ram, data, value: Fmt.percent(Metric.ram.fraction(s)),
                     subtitle: "\(Fmt.gb(s.memUsed)) / \(Fmt.gb(s.memTotal)) · komprim. \(Fmt.gb(s.memCompressed)) · swap \(Fmt.gb(s.swapUsed))")
                card(.disk, data, value: nil,
                     subtitle: "čtení \(Fmt.rate(s.diskRead)) · zápis \(Fmt.rate(s.diskWrite)) · volno \(Fmt.gb(s.diskTotal - s.diskUsed))")
                card(.net, data, value: nil, subtitle: nil)
                if s.gpu != nil {
                    card(.gpu, data, value: Fmt.percent(s.gpu), subtitle: s.gpuMemory.map { "paměť GPU \(Fmt.gb($0))" } ?? "")
                }
            }
            .padding(10)
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
    }

    private func card(_ m: Metric, _ data: [MetricsSnapshot], value: String?, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label(m == .ram ? "Paměť" : m.title, systemImage: m.symbol).font(.headline).foregroundStyle(m.color)
                Spacer()
                if m == .net {
                    InOutLegend(metric: m, snapshot: store.current, font: .caption)
                } else if let value {
                    Text(value).font(.headline).monospacedDigit()
                }
            }
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Sparkline(history: data, metric: m, showAxis: true, showTimeAxis: false)
                .frame(height: 80)
            Text(range.caption).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Load of one core placed by time, so a history shorter than the range fills up from the right.
    private func points(core i: Int, _ data: [MetricsSnapshot]) -> [(x: Double, y: Double)] {
        let end = store.current.date, span = range.seconds
        return data.compactMap { s in
            guard s.cores.count > i else { return nil }
            let x = 1 - end.timeIntervalSince(s.date) / span
            return x >= 0 ? (min(x, 1), s.cores[i]) : nil
        }
    }

    /// One small graph per core, like the CPU tab in Windows. Drawn as plain paths: a dozen Swift Charts
    /// redrawn every second would cost more than the whole rest of the window.
    @ViewBuilder
    private func cores(_ data: [MetricsSnapshot]) -> some View {
        let count = store.current.cores.count
        // Apple Silicon lists efficiency cores first; Intel has none.
        let efficiency = min(SystemSampler.coreLevels.efficiency, count)
        if count > 0 {
            let columns = count > 12 ? 4 : count > 4 ? 3 : 2
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Jádra CPU", systemImage: "square.grid.3x3").font(.headline).foregroundStyle(Metric.cpu.color)
                    Spacer()
                    if efficiency > 0 {
                        Text("E efektivní · P výkonná").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
                    ForEach(0..<count, id: \.self) { i in
                        let efficient = i < efficiency
                        CoreGraph(label: efficient ? "E\(i + 1)" : "P\(i - efficiency + 1)",
                                  color: efficiency == 0 ? Metric.cpu.color : efficient ? .teal : .indigo,
                                  points: points(core: i, data), current: store.current.cores[i])
                    }
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// History of one CPU core: area under the load, 0...100 %.
private struct CoreGraph: View {
    var label: String
    var color: Color
    /// x 0...1 across the selected range (1 = now), load 0...1.
    var points: [(x: Double, y: Double)]
    var current: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.percent(current)).monospacedDigit()
            }
            .font(.caption2)
            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size)
                ctx.fill(Path(rect), with: .color(color.opacity(0.06)))
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: size.height / 2))
                grid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
                guard points.count > 1 else { return }
                func point(_ p: (x: Double, y: Double)) -> CGPoint {
                    CGPoint(x: size.width * CGFloat(p.x), y: size.height * (1 - CGFloat(min(max(p.y, 0), 1))))
                }
                var line = Path()
                line.move(to: point(points[0]))
                for p in points.dropFirst() { line.addLine(to: point(p)) }
                var area = line
                area.addLine(to: CGPoint(x: point(points[points.count - 1]).x, y: size.height))
                area.addLine(to: CGPoint(x: point(points[0]).x, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .color(color.opacity(0.3)))
                ctx.stroke(line, with: .color(color), lineWidth: 1)
            }
            .frame(height: 36)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.secondary.opacity(0.25), lineWidth: 0.5))
        }
    }
}
