import WidgetKit
import SwiftUI

struct MetricsEntry: TimelineEntry {
    var date: Date
    var host: String
    var snapshot: MetricsSnapshot
    var history: [MetricsSnapshot]
}

struct MetricsProvider: TimelineProvider {
    func placeholder(in context: Context) -> MetricsEntry {
        var s = MetricsSnapshot.empty
        s.date = Date(); s.cpu = 0.42; s.diskTotal = 512_000_000_000; s.diskUsed = 300_000_000_000; s.gpu = 0.18; s.memUsed = s.memTotal / 2; s.netIn = 2_400_000; s.netOut = 600_000
        return MetricsEntry(date: Date(), host: "Mac mini", snapshot: s, history: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (MetricsEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MetricsEntry>) -> Void) {
        let (entry, fromApp) = makeEntryWithSource()
        SharedStore.noteWidgetReload(fromApp: fromApp)
        // The app pushes a reload every minute; this is the fallback when it isn't running.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }

    /// Prefers fresh data from the app; otherwise measures on its own.
    private func makeEntry() -> MetricsEntry { makeEntryWithSource().entry }

    private func makeEntryWithSource() -> (entry: MetricsEntry, fromApp: Bool) {
        let state = SharedStore.read()
        if let state, Date().timeIntervalSince(state.latest.date) < 180 {
            return (MetricsEntry(date: state.latest.date, host: state.host, snapshot: state.latest, history: state.history), true)
        }
        let s = SystemSampler.oneShot(interval: 0.5)
        return (MetricsEntry(date: s.date, host: SystemSampler.hostName, snapshot: s, history: state?.history ?? []), false)
    }
}

struct MacMetrixWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: MetricsEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemMedium: medium
            default: large
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var title: some View {
        HStack(spacing: 4) {
            Text(entry.host).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 2)
            Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var small: some View {
        VStack(spacing: 6) {
            title
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow { gauge(.cpu); gauge(.gpu); gauge(.ram) }
                GridRow {
                    gauge(.disk); gauge(.net)
                    if entry.snapshot.battery != nil { gauge(.battery) } else { Color.clear }
                }
            }
        }
    }

    private var medium: some View {
        VStack(spacing: 6) {
            title
            HStack(spacing: 10) {
                ForEach(Metric.shown(in: entry.snapshot)) { m in
                    VStack(spacing: 4) {
                        gauge(m)
                        if entry.history.count > 1 {
                            Sparkline(history: entry.history, metric: m).frame(height: 22)
                        }
                    }
                }
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            title
            ForEach(Metric.shown(in: entry.snapshot)) { m in
                HStack(spacing: 10) {
                    RingGauge(value: m.fraction(entry.snapshot), color: m.color, label: "", lineWidth: 5,
                              stroke: m.strokeColor(m.fraction(entry.snapshot)))
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(m.title).font(.caption).foregroundStyle(.secondary)
                        if m == .net {
                            InOutLegend(metric: m, snapshot: entry.snapshot, font: .caption2)
                        } else {
                            Text(m.valueText(entry.snapshot)).font(.headline).monospacedDigit()
                        }
                        Text(detail(m)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: 122, alignment: .leading)
                    Sparkline(history: entry.history, metric: m)
                }
                .frame(maxHeight: .infinity)
            }
            Text(entry.history.isEmpty ? "Historie se zobrazí po spuštění aplikace" : "Posledních \(entry.history.count) min")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func gauge(_ m: Metric) -> some View {
        VStack(spacing: 2) {
            RingGauge(value: m.fraction(entry.snapshot), color: m.color,
                      label: m.ringLabel(entry.snapshot),
                      lineWidth: 5, stroke: m.strokeColor(m.fraction(entry.snapshot)))
            Text(m.title).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private func detail(_ m: Metric) -> String {
        let s = entry.snapshot
        switch m {
        case .cpu: return "load \(Fmt.load(s.load))"
        case .gpu: return s.gpuMemory.map { String(localized: "paměť \(Fmt.gb($0))") } ?? ""
        case .ram: return "\(Fmt.gb(s.memUsed)) / \(Fmt.gb(s.memTotal))"
        case .disk: return "R \(Fmt.rate(s.diskRead)) W \(Fmt.rate(s.diskWrite))"
        case .net: return "IN \(Fmt.rate(s.netIn)) · OUT \(Fmt.rate(s.netOut))"
        case .battery:
            guard let b = s.battery else { return "" }
            return b.remainingText.map { b.charging ? String(localized: "do nabití \($0)") : String(localized: "zbývá \($0)") } ?? b.stateText
        }
    }
}

struct MacMetrixWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MacMetrixWidget", provider: MetricsProvider()) { entry in
            MacMetrixWidgetView(entry: entry)
        }
        .configurationDisplayName("MacMetrix")
        .description("Zatížení CPU, GPU, RAM, disku, sítě a stav baterie.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct MacMetrixWidgets: WidgetBundle {
    var body: some Widget {
        MacMetrixWidget()
    }
}
