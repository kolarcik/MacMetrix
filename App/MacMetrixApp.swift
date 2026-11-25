import SwiftUI
import ServiceManagement

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case bars, cpu, text, icon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bars: "Sloupce (CPU · GPU · RAM · Disk · Síť)"
        case .cpu: "Ikona + CPU %"
        case .text: "Text (CPU, GPU, RAM)"
        case .icon: "Jen ikona"
        }
    }
}

@main
struct MacMetrixApp: App {
    @StateObject private var store = MonitorStore()
    @AppStorage("menuBarStyle") private var style: MenuBarStyle = .bars

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(snapshot: store.current, style: style)
        }
        .menuBarExtraStyle(.window)

        Window("MacMetrix", id: "dashboard") {
            DashboardView()
                .environmentObject(store)
        }
        .defaultSize(width: 820, height: 780)
    }
}

/// Status bar item content.
struct MenuBarLabel: View {
    var snapshot: MetricsSnapshot
    var style: MenuBarStyle

    var body: some View {
        switch style {
        case .bars:
            Image(nsImage: Self.barsImage(snapshot))
        case .cpu:
            HStack(spacing: 3) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                Text(Fmt.percent(snapshot.cpu)).monospacedDigit()
            }
        case .text:
            Text("CPU \(Fmt.percent(snapshot.cpu))  GPU \(Fmt.percent(snapshot.gpu))  RAM \(Fmt.percent(snapshot.memFraction))")
                .monospacedDigit()
        case .icon:
            Image(systemName: "gauge.with.dots.needle.67percent")
        }
    }

    /// Four tiny vertical bars drawn as a template image (adapts to light / dark menu bar).
    static func barsImage(_ s: MetricsSnapshot) -> NSImage {
        let values = Metric.allCases.map { $0.fraction(s) }
        let barW: CGFloat = 4, gap: CGFloat = 2, h: CGFloat = 16
        let size = NSSize(width: CGFloat(values.count) * barW + CGFloat(values.count - 1) * gap, height: h)
        let image = NSImage(size: size, flipped: false) { _ in
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * (barW + gap)
                NSColor.black.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: barW, height: h - 2), xRadius: 1, yRadius: 1).fill()
                NSColor.black.setFill()
                let fillH = max(1, (h - 2) * CGFloat(min(max(v, 0), 1)))
                NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: barW, height: fillH), xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
