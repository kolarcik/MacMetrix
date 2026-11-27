import SwiftUI

/// Right-hand panel of the Resource Monitor, like the graphs in Windows: total CPU, history of every
/// core, memory, disk, network, battery (on a MacBook) and GPU. Observes the store on its own, so the process
/// tables next to it don't redraw on every sample. `header` goes above the system graphs (graphs of the
/// selected process).
struct ResourceGraphs<Header: View>: View {
    @EnvironmentObject var store: MonitorStore
    @ViewBuilder var header: () -> Header
    /// Kept in defaults: the view is recreated whenever the window comes back on screen.
    @AppStorage("resourcesRange") private var range: Range = .oneMinute

    enum Range: String, CaseIterable, Identifiable {
        case oneMinute = "1 min", fiveMinutes = "5 min", hour = "1 hod"
        var id: String { rawValue }
        var seconds: TimeInterval { self == .oneMinute ? 60 : self == .fiveMinutes ? 300 : 3600 }
        /// Shown in the picker; the raw value is stored in defaults and must not change.
        var title: String {
            switch self {
            case .oneMinute: String(localized: "1 min")
            case .fiveMinutes: String(localized: "5 min")
            case .hour: String(localized: "1 hod")
            }
        }
        var caption: String {
            switch self {
            case .oneMinute: String(localized: "60 sekund")
            case .fiveMinutes: String(localized: "5 minut")
            case .hour: String(localized: "60 minut (minutové průměry)")
            }
        }
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
                    ForEach(Range.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                header()

                card(.cpu, data, value: Fmt.percent(s.cpu),
                     subtitle: String(localized: "usr \(Fmt.percent(s.cpuUser)) · sys \(Fmt.percent(s.cpuSystem)) · load \(Fmt.load(s.load))"))
                cores(data)
                card(.ram, data, value: Fmt.percent(Metric.ram.fraction(s)),
                     subtitle: String(localized: "\(Fmt.gb(s.memUsed)) / \(Fmt.gb(s.memTotal)) · komprim. \(Fmt.gb(s.memCompressed)) · swap \(Fmt.gb(s.swapUsed))"))
                card(.disk, data, value: nil,
                     subtitle: String(localized: "čtení \(Fmt.rate(s.diskRead)) · zápis \(Fmt.rate(s.diskWrite)) · volno \(Fmt.gb(s.diskTotal - s.diskUsed))"))
                card(.net, data, value: nil, subtitle: nil)
                if Metric.available.contains(.battery), let battery = s.battery {
                    card(.battery, data, value: Fmt.percent(battery.level), subtitle: battery.summary)
                }
                if s.gpu != nil {
                    card(.gpu, data, value: Fmt.percent(s.gpu), subtitle: s.gpuMemory.map { String(localized: "paměť GPU \(Fmt.gb($0))") } ?? "")
                }
            }
            .padding(10)
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
    }

    private func card(_ m: Metric, _ data: [MetricsSnapshot], value: String?, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label(m == .ram ? String(localized: "Paměť") : m.title, systemImage: m.symbol).font(.headline).foregroundStyle(m.color)
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
                        // E = efficiency, P = performance core (explained next to the title).
                        MiniGraph(label: efficient ? "E\(i + 1)" : "P\(i - efficiency + 1)",
                                  value: Fmt.percent(store.current.cores[i]),
                                  color: efficiency == 0 ? Metric.cpu.color : efficient ? .teal : .indigo,
                                  points: points(core: i, data))
                    }
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

extension ResourceGraphs where Header == EmptyView {
    init() { self.init(header: { EmptyView() }) }
}

/// Small history graph (one CPU core, one resource of a process): area under the values.
struct MiniGraph: View {
    var label: LocalizedStringKey
    var value: String
    var color: Color
    /// x 0...1 across the shown range (1 = now), y 0...1 of the graph height.
    var points: [(x: Double, y: Double)]
    var height: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit().lineLimit(1)
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
            .frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.secondary.opacity(0.25), lineWidth: 0.5))
        }
    }
}

/// History of the process selected in the tables: CPU, memory, disk and network over the last minutes,
/// collected since the window opened.
struct ProcessGraphs: View {
    @ObservedObject var monitor: ResourceMonitor
    var pid: Int32

    var body: some View {
        if let row = monitor.processes.first(where: { $0.pid == pid }) {
            let samples = monitor.history[pid] ?? []
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(nsImage: ProcessIcon.image(row.pid, name: row.name)).resizable().frame(width: 16, height: 16)
                    Text(row.name).font(.headline).lineLimit(1)
                    Spacer()
                    Text(verbatim: "PID \(row.pid)").font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    graph("CPU", String(format: "%.1f %%", row.cpu), Metric.cpu.color, samples, \.cpu, minScale: 100)
                    graph("Paměť", Fmt.bytes(UInt64(max(samples.last?.memory ?? 0, 0))), Metric.ram.color, samples, \.memory)
                    graph("Disk", samples.last.map { $0.disk < 0 ? "–" : Fmt.rate($0.disk) } ?? "–",
                          Metric.disk.color, samples, \.disk, minScale: 1024)
                    graph("Síť", Fmt.rate(samples.last?.net ?? 0), Metric.net.color, samples, \.net, minScale: 1024)
                }
                Text("Posledních \(Int(ResourceMonitor.historySeconds / 60)) minut od otevření okna")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Values scaled to the highest one shown (at least `minScale`), placed by time.
    private func graph(_ label: LocalizedStringKey, _ value: String, _ color: Color, _ samples: [ResourceMonitor.ProcSample],
                       _ key: KeyPath<ResourceMonitor.ProcSample, Double>, minScale: Double = 1) -> some View {
        let end = samples.last?.date ?? Date()
        let top = max(samples.map { $0[keyPath: key] }.max() ?? 0, minScale)
        let points = samples.compactMap { s -> (x: Double, y: Double)? in
            let x = 1 - end.timeIntervalSince(s.date) / ResourceMonitor.historySeconds
            return x >= 0 ? (min(x, 1), max(s[keyPath: key], 0) / top) : nil
        }
        return MiniGraph(label: label, value: value, color: color, points: points, height: 44)
    }
}
