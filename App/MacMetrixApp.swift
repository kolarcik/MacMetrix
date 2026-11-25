import SwiftUI
import ServiceManagement

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case bars, cpu, text, icon
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bars: "Sloupce (C CPU · G GPU · R RAM · D Disk · S Síť)"
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

    /// Tiny vertical bars with a letter under each (C GPU RAM Disk Síť), drawn as a
    /// template image so it adapts to light / dark menu bar.
    static func barsImage(_ s: MetricsSnapshot) -> NSImage {
        let metrics = Metric.allCases
        let barW: CGFloat = 5, gap: CGFloat = 3
        let labelH: CGFloat = 7, spacing: CGFloat = 1.5, barH: CGFloat = 11
        let h = labelH + spacing + barH
        let size = NSSize(width: CGFloat(metrics.count) * barW + CGFloat(metrics.count - 1) * gap, height: h)
        let font = NSFont.systemFont(ofSize: 7, weight: .bold)
        let image = NSImage(size: size, flipped: false) { _ in
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            for (i, m) in metrics.enumerated() {
                let x = CGFloat(i) * (barW + gap)
                let barY = labelH + spacing
                NSColor.black.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: barY, width: barW, height: barH), xRadius: 1, yRadius: 1).fill()
                NSColor.black.setFill()
                let fillH = max(1, barH * CGFloat(min(max(m.fraction(s), 0), 1)))
                NSBezierPath(roundedRect: NSRect(x: x, y: barY, width: barW, height: fillH), xRadius: 1, yRadius: 1).fill()

                let label = NSAttributedString(string: m.letter, attributes: [
                    .font: font, .foregroundColor: NSColor.black, .paragraphStyle: para])
                label.draw(in: NSRect(x: x - 2, y: -1.5, width: barW + 4, height: labelH + 2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
