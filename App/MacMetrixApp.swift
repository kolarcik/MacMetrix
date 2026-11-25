import SwiftUI
import ServiceManagement

/// How each metric's status bar item looks.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case iconValue, text, bars
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iconValue: "Ikona + hodnota"
        case .text: "Text"
        case .bars: "Sloupec"
        }
    }
}

/// Which metrics have their own status bar item, stored as a comma-separated string in UserDefaults.
enum MenuBarMetrics {
    static let key = "menuBarMetrics"
    static let all = Metric.allCases.map(\.rawValue).joined(separator: ",")

    static func decode(_ raw: String) -> [Metric] {
        let set = Set(raw.split(separator: ",").map(String.init))
        return Metric.allCases.filter { set.contains($0.rawValue) }
    }

    static func encode(_ metrics: [Metric]) -> String {
        metrics.map(\.rawValue).joined(separator: ",")
    }
}

/// Menu bar app: closing the last popover / dashboard window must never quit it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct MacMetrixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = MonitorStore()
    @AppStorage("menuBarStyle") private var style: MenuBarStyle = .iconValue
    @AppStorage(MenuBarMetrics.key) private var metricsRaw = MenuBarMetrics.all

    var body: some Scene {
        // One independent status bar item per metric (SceneBuilder has no ForEach).
        // macOS places items right-to-left in declaration order, so declare them reversed
        // to get CPU · GPU · RAM · Disk · Síť from left to right.
        metricItem(.net)
        metricItem(.disk)
        metricItem(.ram)
        metricItem(.gpu)
        metricItem(.cpu)

        // App icon only when no metric is selected, so the app stays reachable.
        MenuBarExtra(isInserted: Binding(get: { MenuBarMetrics.decode(metricsRaw).isEmpty }, set: { _ in })) {
            popover
        } label: {
            Image(nsImage: AppGlyph.image)
        }
        .menuBarExtraStyle(.window)

        Window("MacMetrix", id: "dashboard") {
            DashboardView()
                .environmentObject(store)
        }
        .defaultSize(width: 820, height: 780)
    }

    private var popover: some View {
        PopoverView().environmentObject(store)
    }

    private func metricItem(_ m: Metric) -> some Scene {
        MenuBarExtra(isInserted: binding(for: m)) {
            popover
        } label: {
            MetricStatusLabel(metric: m, snapshot: store.current, style: style)
        }
        .menuBarExtraStyle(.window)
    }

    /// Also reacts when the user ⌘-drags an item out of the menu bar.
    private func binding(for m: Metric) -> Binding<Bool> {
        Binding(
            get: { MenuBarMetrics.decode(metricsRaw).contains(m) },
            set: { on in
                var list = MenuBarMetrics.decode(metricsRaw).filter { $0 != m }
                if on { list.append(m) }
                metricsRaw = MenuBarMetrics.encode(Metric.allCases.filter(list.contains))
            })
    }
}

/// Content of a single metric's status bar item.
struct MetricStatusLabel: View {
    var metric: Metric
    var snapshot: MetricsSnapshot
    var style: MenuBarStyle

    var body: some View {
        switch style {
        case .iconValue:
            HStack(spacing: 3) {
                Image(systemName: metric.symbol)
                Text(value).monospacedDigit()
            }
        case .text:
            Text(metric == .net ? value : "\(metric.title) \(value)").monospacedDigit()
        case .bars:
            Image(nsImage: Self.barImage(metric, snapshot))
        }
    }

    private var value: String {
        metric == .net
            ? "↓\(Fmt.shortRate(snapshot.netIn)) ↑\(Fmt.shortRate(snapshot.netOut))"
            : metric.valueText(snapshot)
    }

    /// A single vertical bar with the metric's letter under it, drawn as a template image.
    static func barImage(_ m: Metric, _ s: MetricsSnapshot) -> NSImage {
        let barW: CGFloat = 6, labelH: CGFloat = 7, spacing: CGFloat = 1.5, barH: CGFloat = 11
        let size = NSSize(width: 9, height: labelH + spacing + barH)
        let image = NSImage(size: size, flipped: false) { _ in
            let x = (size.width - barW) / 2
            let barY = labelH + spacing
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: barY, width: barW, height: barH), xRadius: 1, yRadius: 1).fill()
            NSColor.black.setFill()
            let fillH = max(1, barH * CGFloat(min(max(m.fraction(s), 0), 1)))
            NSBezierPath(roundedRect: NSRect(x: x, y: barY, width: barW, height: fillH), xRadius: 1, yRadius: 1).fill()

            let para = NSMutableParagraphStyle()
            para.alignment = .center
            NSAttributedString(string: m.letter, attributes: [
                .font: NSFont.systemFont(ofSize: 7, weight: .bold), .foregroundColor: NSColor.black, .paragraphStyle: para,
            ]).draw(in: NSRect(x: 0, y: -1.5, width: size.width, height: labelH + 2))
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Monochrome menu bar version of the app icon (five bars, same proportions as AppIcon).
enum AppGlyph {
    static let image: NSImage = {
        let heights: [CGFloat] = [0.62, 0.38, 0.84, 0.70, 0.48]
        let barW: CGFloat = 3, gap: CGFloat = 1.5, h: CGFloat = 15
        let size = NSSize(width: CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap, height: h)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            for (i, f) in heights.enumerated() {
                let x = CGFloat(i) * (barW + gap)
                NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: barW, height: (h - 2) * f), xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }()
}
