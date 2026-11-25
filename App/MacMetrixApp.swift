import SwiftUI
import ServiceManagement

/// How each metric's status bar item looks.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case stacked, iconValue, text, bars
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stacked: "Dvouřádkově"
        case .iconValue: "Ikona"
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

    /// Something must always stay in the menu bar, otherwise the app can't be reached.
    static func restoreIfEmpty() {
        let raw = UserDefaults.standard.string(forKey: key) ?? all
        if decode(raw).isEmpty { UserDefaults.standard.set(all, forKey: key) }
    }
}

/// Menu bar app: closing the last popover / dashboard window must never quit it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app again (Finder, Spotlight) while it runs with no status item brings the default items back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MenuBarMetrics.restoreIfEmpty()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one status bar popover at a time: when one opens, close the others.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, MenuBarWindows.isPopover(window) else { return }
            MenuBarWindows.closeAll(except: window)
        }
    }
}

/// Helpers for the windows SwiftUI creates for `MenuBarExtra(.window)`.
enum MenuBarWindows {
    static func isPopover(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("MenuBarExtraWindow")
    }

    static func closeAll(except keep: NSWindow? = nil) {
        for w in NSApp.windows where w !== keep && w.isVisible && isPopover(w) {
            w.close()
        }
    }
}

@main
struct MacMetrixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = MonitorStore()
    @AppStorage("menuBarStyle") private var style: MenuBarStyle = .stacked
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
        // If the user ⌘-drags it out anyway, bring the metric items back instead of leaving nothing.
        MenuBarExtra(isInserted: Binding(get: { MenuBarMetrics.decode(metricsRaw).isEmpty },
                                         set: { if !$0 { metricsRaw = MenuBarMetrics.all } })) {
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

        Window("Úklid disku", id: "cleanup") {
            CleanupView()
                .environmentObject(store)
        }
        .defaultSize(width: 680, height: 640)

        Window("O aplikaci MacMetrix", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("Nastavení MacMetrix", id: "settings") {
            SettingsView()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
    }

    private var popover: some View {
        PopoverView().environmentObject(store)
    }

    private func metricItem(_ m: Metric) -> some Scene {
        MenuBarExtra(isInserted: binding(for: m)) {
            MetricDetailView(metric: m).environmentObject(store)
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

/// Content of a single metric's status bar item. Always a fixed-width template image,
/// so items don't shift sideways as values change.
struct MetricStatusLabel: View {
    var metric: Metric
    var snapshot: MetricsSnapshot
    var style: MenuBarStyle

    var body: some View {
        Image(nsImage: StatusImage.render(metric, snapshot, style))
            .accessibilityLabel("\(metric.title) \(metric.valueText(snapshot))")
    }
}

/// Draws status bar items with widths computed from the widest possible value.
enum StatusImage {
    static let height: CGFloat = 22

    static func render(_ m: Metric, _ s: MetricsSnapshot, _ style: MenuBarStyle) -> NSImage {
        switch style {
        case .stacked: m == .net ? netStacked(s) : stacked(m, s)
        case .iconValue: iconValue(m, s)
        case .text: text(m, s)
        case .bars: bar(m, s)
        }
    }

    // MARK: Styles

    /// Small caption on top, big value below (like iStat Menus).
    private static func stacked(_ m: Metric, _ s: MetricsSnapshot) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 8.5, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        let label = m.title.uppercased()
        let w = max(width("100%", valueFont), width(label, labelFont))
        return image(width: w) {
            draw(label, labelFont, x: 0, baseline: 14)
            draw(m.valueText(s), valueFont, x: 0, baseline: 2.5)
        }
    }

    /// Upload on top, download below, values right-aligned.
    private static func netStacked(_ s: MetricsSnapshot) -> NSImage {
        image(width: netBlockWidth) { drawNetBlock(s, x: 0) }
    }

    private static func iconValue(_ m: Metric, _ s: MetricsSnapshot) -> NSImage {
        let symbol = symbolImage(m)
        let gap: CGFloat = 3
        if m == .net {
            return image(width: symbol.size.width + gap + netBlockWidth) {
                drawSymbol(symbol)
                drawNetBlock(s, x: symbol.size.width + gap)
            }
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let vw = width("100%", font)
        return image(width: symbol.size.width + gap + vw) {
            drawSymbol(symbol)
            draw(m.valueText(s), font, x: symbol.size.width + gap, baseline: centeredBaseline(font), width: vw, align: .right)
        }
    }

    private static func text(_ m: Metric, _ s: MetricsSnapshot) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let base = centeredBaseline(font)
        if m == .net {
            let arrow = width("↓", font), field = width("999K", font), gap: CGFloat = 5
            return image(width: 2 * (arrow + field) + gap) {
                draw("↓", font, x: 0, baseline: base)
                draw(Fmt.shortRate(s.netIn), font, x: arrow, baseline: base, width: field, align: .right)
                draw("↑", font, x: arrow + field + gap, baseline: base)
                draw(Fmt.shortRate(s.netOut), font, x: 2 * arrow + field + gap, baseline: base, width: field, align: .right)
            }
        }
        let label = m.title + " "
        let lw = width(label, font), vw = width("100%", font)
        return image(width: lw + vw) {
            draw(label, font, x: 0, baseline: base)
            draw(m.valueText(s), font, x: lw, baseline: base, width: vw, align: .right)
        }
    }

    /// A single vertical bar with the metric's letter under it.
    private static func bar(_ m: Metric, _ s: MetricsSnapshot) -> NSImage {
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

    // MARK: Network block (two rows)

    private static let netFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    private static let netArrowWidth = width("↑", netFont) + 2
    private static let netFieldWidth = width("999 KB/s", netFont)
    private static let netBlockWidth = netArrowWidth + netFieldWidth

    private static func drawNetBlock(_ s: MetricsSnapshot, x: CGFloat) {
        draw("↑", netFont, x: x, baseline: 12.5)
        draw(Fmt.rate(s.netOut), netFont, x: x + netArrowWidth, baseline: 12.5, width: netFieldWidth, align: .right)
        draw("↓", netFont, x: x, baseline: 2)
        draw(Fmt.rate(s.netIn), netFont, x: x + netArrowWidth, baseline: 2, width: netFieldWidth, align: .right)
    }

    // MARK: Drawing helpers

    private static func image(width: CGFloat, _ body: @escaping () -> Void) -> NSImage {
        let img = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            body()
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func attributed(_ str: String, _ font: NSFont) -> NSAttributedString {
        NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    private static func width(_ str: String, _ font: NSFont) -> CGFloat {
        ceil(attributed(str, font).size().width)
    }

    private static func centeredBaseline(_ font: NSFont) -> CGFloat {
        ((height - font.capHeight) / 2).rounded()
    }

    /// Draws text with its baseline at `baseline`; right-aligns inside `width` when given.
    private static func draw(_ str: String, _ font: NSFont, x: CGFloat, baseline: CGFloat,
                             width: CGFloat? = nil, align: NSTextAlignment = .left) {
        let a = attributed(str, font)
        var px = x
        if let width, align == .right { px = x + width - a.size().width }
        a.draw(at: NSPoint(x: px, y: baseline + font.descender))
    }

    private static func symbolImage(_ m: Metric) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: m.symbol, accessibilityDescription: m.title)?
            .withSymbolConfiguration(config) ?? NSImage()
    }

    private static func drawSymbol(_ symbol: NSImage) {
        let y = ((height - symbol.size.height) / 2).rounded()
        symbol.draw(in: NSRect(x: 0, y: y, width: symbol.size.width, height: symbol.size.height))
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
