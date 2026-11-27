import SwiftUI

/// Popover of a single metric's status bar item: gauges, history, details and top processes.
struct MetricDetailView: View {
    var metric: Metric
    @EnvironmentObject var store: MonitorStore
    @StateObject private var procs: ProcessMonitor
    @Environment(\.openWindow) private var openWindow

    init(metric: Metric) {
        self.metric = metric
        _procs = StateObject(wrappedValue: ProcessMonitor(metric: metric))
    }

    private var s: MetricsSnapshot { store.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            gauges
            SectionHeader(metric == .battery ? "Historie nabití" : "Historie použití")
            history
            SectionHeader("Detaily")
            details
            extraSections
            if procs.isSupported {
                SectionHeader("Nejaktivnější procesy")
                processList
            }
            Divider().padding(.top, 2)
            PopoverFooter()
        }
        .padding(12)
        .frame(width: 320)
        .background(WindowReader { procs.window = $0 })
        .onAppear { procs.start() }
        .onDisappear { procs.stop() }
    }

    // MARK: Header & gauges

    private var header: some View {
        HStack {
            Image(systemName: metric.symbol(for: s)).foregroundStyle(metric.color)
            Spacer()
            Text(metric.longTitle).font(.headline)
            Spacer()
            Text(store.hostName).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 70, alignment: .trailing)
        }
    }

    private var gauges: some View {
        let (left, right) = sideGauges
        return HStack(alignment: .center) {
            SmallGauge(gauge: left)
            Spacer()
            RingGauge(value: metric.fraction(s), color: metric.color, label: metric.ringLabel(s), lineWidth: 8,
                      stroke: metric.strokeColor(metric.fraction(s)))
                .frame(width: 92, height: 92)
            Spacer()
            SmallGauge(gauge: right)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var sideGauges: (GaugeSpec, GaugeSpec) {
        switch metric {
        case .cpu:
            let cores = Double(max(s.cores.count, 1))
            let temp = s.cpuTemp.map { GaugeSpec(caption: "Teplota", value: $0 / 105, label: Fmt.temp($0), color: .orange) }
                ?? GaugeSpec(caption: "Uživatel", value: s.cpuUser, label: Fmt.percent(s.cpuUser), color: .blue)
            return (temp,
                    GaugeSpec(caption: "Load 1 min", value: (s.load.first ?? 0) / cores,
                          label: String(format: "%.2f", s.load.first ?? 0), color: .cyan))
        case .gpu:
            return (GaugeSpec(caption: "Renderer", value: s.gpuRenderer ?? 0, label: Fmt.percent(s.gpuRenderer), color: .purple),
                    GaugeSpec(caption: "Tiler", value: s.gpuTiler ?? 0, label: Fmt.percent(s.gpuTiler), color: .indigo))
        case .ram:
            let total = Double(max(s.memTotal, 1))
            return (GaugeSpec(caption: "Komprimovaná", value: Double(s.memCompressed) / total,
                          label: Fmt.percent(Double(s.memCompressed) / total), color: .purple),
                    GaugeSpec(caption: "Swap", value: Double(s.swapUsed) / total, label: Fmt.shortGB(s.swapUsed), color: .red))
        case .disk:
            return (GaugeSpec(caption: "Čtení", value: s.diskRead / peak(\.diskRead), label: Fmt.shortRate(s.diskRead), color: .pink),
                    GaugeSpec(caption: "Zápis", value: s.diskWrite / peak(\.diskWrite), label: Fmt.shortRate(s.diskWrite), color: .indigo))
        case .net:
            return (GaugeSpec(caption: "Stahování", value: s.netIn / peak(\.netIn), label: Fmt.shortRate(s.netIn), color: Metric.net.inColor),
                    GaugeSpec(caption: "Odesílání", value: s.netOut / peak(\.netOut), label: Fmt.shortRate(s.netOut), color: Metric.net.outColor))
        case .battery:
            let b = s.battery
            let watts = b?.systemPower ?? b?.batteryPower.map(abs)
            // Power draw relative to the adapter (or a typical 60 W when on battery).
            let scale = Double(b?.adapterWatts ?? 60)
            return (GaugeSpec(caption: "Kondice", value: b?.health ?? 0, label: Fmt.percent(b?.health), color: .green,
                              stroke: (b?.health ?? 1) < 0.8 ? .orange : .green),
                    GaugeSpec(caption: "Příkon", value: (watts ?? 0) / scale, label: watts.map(Fmt.watts) ?? "–", color: .orange))
        }
    }

    /// Highest value in the visible history (at least 1 MB/s) – scale for rate gauges.
    private func peak(_ k: KeyPath<MetricsSnapshot, Double>) -> Double {
        max(store.history.map { $0[keyPath: k] }.max() ?? 0, 1_000_000)
    }

    // MARK: History

    private var history: some View {
        VStack(spacing: 6) {
            Sparkline(history: store.history, metric: metric)
                .frame(height: 64)
                .padding(4)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            if metric == .cpu, !s.cores.isEmpty {
                CoreBars(cores: s.cores, efficiency: SystemSampler.coreLevels.efficiency)
                    .frame(height: 40)
            }
            if metric.isRateChart {
                InOutLegend(metric: metric, snapshot: s, font: .caption2)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Details

    @ViewBuilder private var details: some View {
        switch metric {
        case .cpu:
            let e = SystemSampler.coreLevels.efficiency
            DetailRow("Systém", Fmt.percent(s.cpuSystem), dot: .red)
            DetailRow("Uživatel", Fmt.percent(s.cpuUser), dot: .blue)
            DetailRow("Nečinný", Fmt.percent(1 - s.cpu), dot: .gray.opacity(0.5))
            if e > 0, s.cores.count > e {
                DetailRow("Efektivní jádra", Fmt.percent(avg(s.cores.prefix(e))), dot: .teal)
                DetailRow("Výkonná jádra", Fmt.percent(avg(s.cores.dropFirst(e))), dot: .indigo)
                DetailRow("Jádra", String(localized: "\(s.cores.count - e) výkonných + \(e) efektivních"))
            } else {
                DetailRow("Jádra", "\(s.cores.count)")
            }
            if let t = s.cpuTemp {
                DetailRow("Teplota (průměr / max)", "\(Fmt.temp(t)) / \(Fmt.temp(s.cpuTempMax ?? t))", dot: .orange)
            }
            DetailRow("Spuštěno", Fmt.uptime(ProcessInfo.processInfo.systemUptime))
        case .gpu:
            DetailRow("Využití", Fmt.percent(s.gpu), dot: .purple)
            DetailRow("Renderer", Fmt.percent(s.gpuRenderer), dot: .purple.opacity(0.6))
            DetailRow("Tiler", Fmt.percent(s.gpuTiler), dot: .indigo)
            DetailRow("Paměť GPU", s.gpuMemory.map(Fmt.gb) ?? "–")
            DetailRow("Čip", store.chipName)
        case .ram:
            MemoryBar(s: s).frame(height: 8).padding(.bottom, 2)
            DetailRow("Tlak paměti", pressureText, dot: pressureColor)
            DetailRow("Aplikace", Fmt.gb(s.memApp ?? 0), dot: .orange)
            DetailRow("Pevně alokovaná", Fmt.gb(s.memWired), dot: .yellow)
            DetailRow("Komprimovaná", Fmt.gb(s.memCompressed), dot: .purple)
            DetailRow("Mezipaměť souborů", Fmt.gb(s.memCached ?? 0), dot: .blue.opacity(0.6))
            DetailRow("Volná", Fmt.gb(s.memFree ?? 0), dot: .gray.opacity(0.5))
            DetailRow("Swap", Fmt.gb(s.swapUsed))
            DetailRow("Celkem", "\(Fmt.gb(s.memUsed)) / \(Fmt.gb(s.memTotal))")
        case .disk:
            DetailRow("Svazek", FileManager.default.displayName(atPath: "/"))
            DetailRow("Obsazeno", Fmt.gb(s.diskUsed), dot: .pink)
            DetailRow("Volno", Fmt.gb(s.diskTotal > s.diskUsed ? s.diskTotal - s.diskUsed : 0), dot: .gray.opacity(0.5))
            DetailRow("Celkem", Fmt.gb(s.diskTotal))
            if let t = s.ssdTemp { DetailRow("Teplota SSD", Fmt.temp(t), dot: .orange) }
        case .net:
            DetailRow(s.netInViaTunnel == true ? "Stahování (VPN)" : "Stahování", Fmt.rate(s.netIn), dot: Metric.net.inColor)
            DetailRow("Odesílání", Fmt.rate(s.netOut), dot: Metric.net.outColor)
            DetailRow("Přijato od startu", s.netInTotal.map(Fmt.bytes) ?? "–")
            DetailRow("Odesláno od startu", s.netOutTotal.map(Fmt.bytes) ?? "–")
        case .battery:
            if let b = s.battery {
                DetailRow("Nabití", Fmt.percent(b.level), dot: Metric.battery.strokeColor(b.level))
                DetailRow("Stav", b.stateText)
                if let t = b.remainingText {
                    DetailRow(b.charging ? "Do plného nabití" : "Zbývá", t)
                } else if !b.onAC {
                    DetailRow("Zbývá", String(localized: "Počítám…"))
                }
                DetailRow("Zdroj napájení", b.onAC ? (b.adapterWatts.map { String(localized: "Adaptér \($0) W") } ?? String(localized: "Adaptér")) : String(localized: "Baterie"))
            } else {
                DetailRow("Baterie", String(localized: "Nedostupná"))
            }
        }
    }

    @ViewBuilder private var extraSections: some View {
        switch metric {
        case .cpu:
            SectionHeader("Průměrné zatížení")
            DetailRow("1 minuta", String(format: "%.2f", s.load[safe: 0] ?? 0))
            DetailRow("5 minut", String(format: "%.2f", s.load[safe: 1] ?? 0))
            DetailRow("15 minut", String(format: "%.2f", s.load[safe: 2] ?? 0))
        case .disk:
            SectionHeader("Aktivita")
            DetailRow("Čtení", Fmt.rate(s.diskRead), dot: .pink)
            DetailRow("Zápis", Fmt.rate(s.diskWrite), dot: .indigo)
            DetailRow("Přečteno od startu", s.diskReadTotal.map(Fmt.bytes) ?? "–")
            DetailRow("Zapsáno od startu", s.diskWriteTotal.map(Fmt.bytes) ?? "–")
            Button {
                MenuBarWindows.closeAll()
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "cleanup")
            } label: {
                Label("Uvolnit místo na disku…", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(.top, 4)
        case .battery:
            if let b = s.battery {
                SectionHeader("Napájení")
                if let w = b.systemPower { DetailRow("Příkon systému", Fmt.watts(w), dot: .orange) }
                if let w = b.batteryPower, abs(w) >= 0.1 { // ~0 W: full or paused, nothing flows
                    DetailRow(w > 0 ? "Nabíjení baterie" : "Vybíjení baterie", Fmt.watts(abs(w)), dot: w > 0 ? .green : .red)
                }
                SectionHeader("Stav baterie")
                DetailRow("Kondice", Fmt.percent(b.health), dot: .green)
                DetailRow("Cykly", b.cycles.map(String.init) ?? "–")
                if let t = b.temperature { DetailRow("Teplota", Fmt.temp(t), dot: .orange) }
            }
        case .net:
            SectionHeader("Rozhraní")
            if procs.interfaces.isEmpty {
                DetailRow("Žádné aktivní rozhraní", "")
            }
            ForEach(procs.interfaces, id: \.name) { i in
                DetailRow(i.name, i.address)
            }
        default:
            EmptyView()
        }
    }

    private var pressureText: String {
        switch s.memPressure {
        case 1: String(localized: "Normální")
        case 2: String(localized: "Zvýšený")
        case 4: String(localized: "Kritický")
        default: "–"
        }
    }

    private var pressureColor: Color {
        switch s.memPressure {
        case 2: .yellow
        case 4: .red
        default: .green
        }
    }

    // MARK: Processes

    private var processList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Proces")
                Spacer()
                Text(processColumn)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if procs.top.isEmpty {
                Text(metric.isRateChart ? "Žádná aktivita" : "Načítám…")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            }
            ForEach(procs.top) { p in
                HStack(spacing: 6) {
                    Image(nsImage: ProcessIcon.image(p.pid, name: p.name))
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(processValue(p)).monospacedDigit().fontWeight(.medium)
                }
                .font(.callout)
            }
            if metric == .disk {
                Text("Jen procesy přihlášeného uživatele.").font(.caption2).foregroundStyle(.tertiary)
            }
            if metric == .battery {
                Text("Podle zatížení procesoru – ty baterii vybíjejí nejvíc.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var processColumn: String {
        switch metric {
        case .cpu: String(localized: "Využití")
        case .ram: String(localized: "Paměť")
        case .disk: String(localized: "Čtení / zápis")
        case .net: "↓ / ↑"
        case .battery: "CPU"
        case .gpu: ""
        }
    }

    private func processValue(_ p: ProcessUsage) -> String {
        switch metric {
        case .cpu, .battery: String(format: "%.1f%%", p.value)
        case .ram: Fmt.bytes(UInt64(p.value))
        case .disk, .net: "\(Fmt.shortRate(p.value)) / \(Fmt.shortRate(p.secondary))"
        case .gpu: ""
        }
    }

    private func avg<C: Collection>(_ c: C) -> Double where C.Element == Double {
        c.isEmpty ? 0 : c.reduce(0, +) / Double(c.count)
    }
}

// MARK: - Building blocks

extension Metric {
    var longTitle: String {
        switch self {
        case .cpu: String(localized: "Procesor")
        case .gpu: String(localized: "Grafika")
        case .ram: String(localized: "Paměť")
        case .disk: String(localized: "Disk")
        case .net: String(localized: "Síť")
        case .battery: String(localized: "Baterie")
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension Fmt {
    static func temp(_ c: Double) -> String { "\(Int(c.rounded())) °C" }

    /// "3.2G" style for small gauges.
    static func shortGB(_ v: UInt64) -> String {
        let g = Double(v) / 1_073_741_824
        return g < 10 ? String(format: "%.1fG", g) : String(format: "%.0fG", g)
    }
}

struct GaugeSpec {
    var caption: LocalizedStringKey
    var value: Double
    var label: String
    var color: Color
    /// Fixed arc color; nil = turns yellow / red at high values.
    var stroke: Color? = nil
}

private struct SmallGauge: View {
    var gauge: GaugeSpec
    var body: some View {
        VStack(spacing: 4) {
            RingGauge(value: gauge.value, color: gauge.color, label: gauge.label, lineWidth: 5, stroke: gauge.stroke)
                .frame(width: 58, height: 58)
            Text(gauge.caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 76)
    }
}

/// Centered uppercase caption between two hairlines.
struct SectionHeader: View {
    var title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }
    var body: some View {
        HStack(spacing: 8) {
            line
            Text(title)
                .textCase(.uppercase)
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
                .fixedSize()
            line
        }
        .padding(.top, 4)
    }
    private var line: some View { Rectangle().fill(.quaternary).frame(height: 1) }
}

/// "● Label ........ value" row.
struct DetailRow: View {
    var label: Text
    var value: String
    var dot: Color?
    /// Literal labels are localized, like `Text("…")`.
    init(_ label: LocalizedStringKey, _ value: String, dot: Color? = nil) {
        self.label = Text(label)
        self.value = value
        self.dot = dot
    }
    /// Data labels (interface names…) are shown verbatim, like `Text(someString)`.
    @_disfavoredOverload
    init<S: StringProtocol>(_ label: S, _ value: String, dot: Color? = nil) {
        self.label = Text(label)
        self.value = value
        self.dot = dot
    }
    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                RoundedRectangle(cornerRadius: 2).fill(dot).frame(width: 9, height: 9)
            }
            label.lineLimit(1)
            Spacer(minLength: 8)
            Text(value).fontWeight(.semibold).monospacedDigit().lineLimit(1)
        }
        .font(.callout)
    }
}

/// Per-core vertical bars: efficiency cores teal, performance cores indigo.
private struct CoreBars: View {
    var cores: [Double]
    var efficiency: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(cores.enumerated()), id: \.offset) { i, v in
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(i < efficiency ? Color.teal : Color.indigo)
                            .frame(height: max(2, geo.size.height * min(max(v, 0), 1)))
                    }
                }
            }
        }
    }
}

/// Stacked bar of RAM composition: app, wired, compressed, cached, free.
struct MemoryBar: View {
    var s: MetricsSnapshot
    var body: some View {
        let parts: [(UInt64, Color)] = [
            (s.memApp ?? 0, .orange), (s.memWired, .yellow), (s.memCompressed, .purple),
            (s.memCached ?? 0, .blue.opacity(0.6)),
        ]
        let total = Double(max(s.memTotal, 1))
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Rectangle().fill(p.1).frame(width: max(0, geo.size.width * Double(p.0) / total))
                }
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

/// Hands the hosting NSWindow to a closure whenever the view moves into (or out of) a window.
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    final class WindowView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [weak self] in self?.onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
        view.onWindow = onWindow
        if let window = view.window { DispatchQueue.main.async { onWindow(window) } }
    }
}
