import SwiftUI
import Charts

enum Metric: String, CaseIterable, Identifiable {
    case cpu, gpu, ram, disk, net
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ram: "RAM"
        case .disk: "Disk"
        case .net: "Síť"
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
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up"
        case .ram: "memorychip"
        case .disk: "internaldrive"
        case .net: "network"
        }
    }

    var color: Color {
        switch self {
        case .cpu: .blue
        case .gpu: .purple
        case .ram: .orange
        case .disk: .pink
        case .net: .green
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
        }
    }

    func valueText(_ s: MetricsSnapshot) -> String {
        switch self {
        case .cpu: Fmt.percent(s.cpu)
        case .gpu: Fmt.percent(s.gpu)
        case .ram: Fmt.percent(s.memFraction)
        case .disk: Fmt.percent(s.diskFraction)
        case .net: Fmt.rate(s.netIn + s.netOut)
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

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(value, 1)))
                .stroke(loadColor(color, value), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
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

    init(history: [MetricsSnapshot], metric: Metric, showAxis: Bool = false) {
        color = metric.inColor
        outColor = metric.outColor
        self.showAxis = showAxis
        switch metric {
        case .net, .disk:
            autoScale = true
            points = history.enumerated().flatMap { i, s in
                [Point(id: i * 2, date: s.date, value: metric == .net ? s.netIn : s.diskRead, series: "in"),
                 Point(id: i * 2 + 1, date: s.date, value: metric == .net ? s.netOut : s.diskWrite, series: "out")]
            }
        default:
            points = history.enumerated().map { i, s in
                Point(id: i, date: s.date, value: metric.fraction(s), series: "v")
            }
        }
    }

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
        .chartXAxis(showAxis ? .automatic : .hidden)
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
