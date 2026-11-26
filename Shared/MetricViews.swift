import SwiftUI
import Charts

enum Metric: String, CaseIterable, Identifiable {
    case cpu, gpu, ram, disk, net, battery
    var id: String { rawValue }

    /// Metrics this Mac can show: the battery only on Macs that have one.
    static let available: [Metric] = allCases.filter { $0 != .battery || Battery.isPresent }

    /// Metrics to show for a snapshot: the battery when the snapshot has battery data. For the sandboxed
    /// widget, which may not be allowed to look the battery up itself but gets it from the app.
    static func shown(in s: MetricsSnapshot) -> [Metric] {
        allCases.filter { $0 != .battery || s.battery != nil }
    }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ram: "RAM"
        case .disk: "Disk"
        case .net: "Síť"
        case .battery: "Baterie"
        }
    }

    /// One-letter label under the menu bar bars.
    var letter: String {
        switch self {
        case .cpu: "C"
        case .gpu: "G"
        case .ram: "R"
        case .disk: "D"
        case .net: "S"
        case .battery: "B"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up"
        case .ram: "memorychip"
        case .disk: "internaldrive"
        case .net: "network"
        case .battery: "battery.75percent"
        }
    }

    var color: Color {
        switch self {
        case .cpu: .blue
        case .gpu: .purple
        case .ram: .orange
        case .disk: .pink
        case .net: .green
        case .battery: .mint
        }
    }

    /// Charts show throughput (bytes/s) instead of a 0...1 value.
    var isRateChart: Bool { self == .net || self == .disk }

    /// 0...1 value for gauges. Disk = used capacity, network is relative to 125 MB/s (1 Gbit).
    func fraction(_ s: MetricsSnapshot) -> Double {
        switch self {
        case .cpu: s.cpu
        case .gpu: s.gpu ?? 0
        case .ram: s.memFraction
        case .disk: s.diskFraction
        case .net: min((s.netIn + s.netOut) / 125_000_000, 1)
        case .battery: s.battery?.level ?? 0
        }
    }

    func valueText(_ s: MetricsSnapshot) -> String {
        switch self {
        case .cpu: Fmt.percent(s.cpu)
        case .gpu: Fmt.percent(s.gpu)
        case .ram: Fmt.percent(s.memFraction)
        case .disk: Fmt.percent(s.diskFraction)
        case .net: Fmt.rate(s.netIn + s.netOut)
        case .battery: Fmt.percent(s.battery?.level)
        }
    }

    /// Gauge color: high load is bad for most metrics, a low charge is bad for the battery.
    func strokeColor(_ v: Double) -> Color {
        guard self == .battery else { return loadColor(color, v) }
        return v <= 0.1 ? .red : v <= 0.2 ? .yellow : color
    }

    /// SF Symbol that follows the battery charge (and shows a bolt while charging).
    func symbol(for s: MetricsSnapshot) -> String {
        guard self == .battery, let b = s.battery else { return symbol }
        if b.charging || (b.onAC && b.fullyCharged) { return "battery.100percent.bolt" }
        switch b.level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

extension Metric {
    /// Color of the second series (OUT / write) in rate charts.
    var outColor: Color { self == .disk ? .indigo : .red }
    /// Color of the first series (IN / read) in rate charts.
    var inColor: Color { self == .net ? .blue : color }

    /// Text inside ring gauges – network shows IN and OUT on two lines.
    func ringLabel(_ s: MetricsSnapshot) -> String {
        self == .net ? "↓\(Fmt.shortRate(s.netIn))\n↑\(Fmt.shortRate(s.netOut))" : valueText(s)
    }
}

/// Color-coded IN / OUT (network) or READ / WRITE (disk) values, matching the chart colors.
struct InOutLegend: View {
    var metric: Metric
    var snapshot: MetricsSnapshot
    var font: Font = .caption

    var body: some View {
        let net = metric == .net
        HStack(spacing: 10) {
            item(net ? (snapshot.netInViaTunnel == true ? "IN ↓ (VPN)" : "IN ↓") : "R",
                 net ? snapshot.netIn : snapshot.diskRead, metric.inColor)
            item(net ? "OUT ↑" : "W", net ? snapshot.netOut : snapshot.diskWrite, metric.outColor)
        }
    }

    private func item(_ title: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(.secondary)
            Text(Fmt.rate(value)).fontWeight(.semibold).monospacedDigit()
        }
        .font(font)
        .lineLimit(1)
    }
}

/// Color that turns yellow / red under heavy load.
func loadColor(_ base: Color, _ v: Double) -> Color {
    v >= 0.9 ? .red : v >= 0.75 ? .yellow : base
}

/// Small ring gauge with a value in the middle.
struct RingGauge: View {
    var value: Double
    var color: Color
    var label: String
    var lineWidth: CGFloat = 6
    /// Color of the filled arc; default turns yellow / red under heavy load.
    var stroke: Color? = nil

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(value, 1)))
                .stroke(stroke ?? loadColor(color, value), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.4)
                .lineLimit(label.contains("\n") ? 2 : 1)
                .multilineTextAlignment(.center)
                .padding(lineWidth + 2)
        }
    }
}

/// Area chart over time. `values` are 0...1 unless `autoScale` is set.
struct Sparkline: View {
    struct Point: Identifiable { var id: Int; var date: Date; var value: Double; var series: String }
    var points: [Point]
    var color: Color
    var outColor: Color = .teal
    var autoScale = false
    var showAxis = false
    /// Time labels under the chart; narrow charts show only the value axis.
    var showTimeAxis = true

    init(history: [MetricsSnapshot], metric: Metric, showAxis: Bool = false, showTimeAxis: Bool = true) {
        color = metric.inColor
        outColor = metric.outColor
        self.showAxis = showAxis
        self.showTimeAxis = showTimeAxis
        switch metric {
        case .net, .disk:
            autoScale = true
            points = history.flatMap { s in
                [Point(id: Self.id(s.date) * 2, date: s.date, value: metric == .net ? s.netIn : s.diskRead, series: "in"),
                 Point(id: Self.id(s.date) * 2 + 1, date: s.date, value: metric == .net ? s.netOut : s.diskWrite, series: "out")]
            }
        default:
            points = history.map { s in
                Point(id: Self.id(s.date), date: s.date, value: metric.fraction(s), series: "v")
            }
        }
    }

    /// Ids tied to the sample time, not the array index: when the window slides by one sample,
    /// SwiftUI only inserts / removes one point instead of updating every mark.
    private static func id(_ date: Date) -> Int { Int(date.timeIntervalSinceReferenceDate * 1000) }

    var body: some View {
        Chart(points) { p in
            if p.series == "out" {
                LineMark(x: .value("t", p.date), y: .value("v", p.value), series: .value("s", p.series))
                    .foregroundStyle(outColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
            } else {
                AreaMark(x: .value("t", p.date), y: .value("v", p.value), series: .value("s", p.series))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.55), color.opacity(0.05)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", p.date), y: .value("v", p.value), series: .value("s", p.series))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: autoScale ? 0...max(points.map(\.value).max() ?? 1, 1024) : 0...1)
        .chartXAxis(showAxis && showTimeAxis ? .automatic : .hidden)
        .chartYAxis {
            if showAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(autoScale ? Fmt.rate(d) : Fmt.percent(d)).font(.caption2)
                        }
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }
}
