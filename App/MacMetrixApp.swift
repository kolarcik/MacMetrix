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
        return Metric.available.filter { set.contains($0.rawValue) }
    }

    static func encode(_ metrics: [Metric]) -> String {
        metrics.map(\.rawValue).joined(separator: ",")
    }

    /// The battery metric came in 1.1: show it once to users whose saved selection predates it.
    static func addBatteryOnce() {
        let flag = "didAddBatteryMetric"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        guard Battery.isPresent, let raw = defaults.string(forKey: key), !raw.split(separator: ",").contains("battery") else { return }
        defaults.set(raw.isEmpty ? Metric.battery.rawValue : raw + ",battery", forKey: key)
    }

    /// Something must always stay in the menu bar, otherwise the app can't be reached.
    /// Also gives items hidden by macOS another chance to appear.
    static func restoreIfEmpty() {
        HiddenBySystem.shared.metrics.removeAll()
        let raw = UserDefaults.standard.string(forKey: key) ?? all
        if decode(raw).isEmpty { UserDefaults.standard.set(all, forKey: key) }
    }
}

/// Metric items macOS took out of the menu bar on its own (no room). Not saved: they stay selected
/// in Settings and get another chance on the next launch, when the app is opened again, or when the
/// metric is switched off and on in Settings.
final class HiddenBySystem: ObservableObject {
    static let shared = HiddenBySystem()
    @Published var metrics: Set<Metric> = []
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
    @AppStorage(StatusImage.sparklineKey) private var showSparkline = false
    @ObservedObject private var hiddenBySystem = HiddenBySystem.shared

    init() {
        MenuBarMetrics.addBatteryOnce()
    }

    var body: some Scene {
        // One independent status bar item per metric (SceneBuilder has no ForEach).
        // macOS places items right-to-left in declaration order, so declare them reversed
        // to get CPU · GPU · RAM · Disk · Síť · Baterie from left to right.
        metricItem(.battery)
        metricItem(.net)
        metricItem(.disk)
        metricItem(.ram)
        metricItem(.gpu)
        metricItem(.cpu)

        // App icon only when no metric is selected, so the app stays reachable.
        // If the user ⌘-drags it out anyway, bring the metric items back instead of leaving nothing.
        MenuBarExtra(isInserted: Binding(get: { MenuBarMetrics.decode(metricsRaw).isEmpty },
                                         set: { inserted in
                                             // SwiftUI also writes false when the item goes away because a metric
                                             // got selected – only react when the selection is still empty.
                                             if !inserted, MenuBarMetrics.decode(metricsRaw).isEmpty {
                                                 hiddenBySystem.metrics.removeAll()
                                                 metricsRaw = MenuBarMetrics.all
                                             }
                                         })) {
            popover
        } label: {
            Image(nsImage: AppGlyph.image)
        }
        .menuBarExtraStyle(.window)

        Window("MacMetrix", id: "dashboard") {
            WhenVisible { DashboardView().environmentObject(store) }
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
            WhenVisible { SettingsView().environmentObject(store) }
        }
        .windowResizability(.contentSize)
    }

    private var popover: some View {
        WhenVisible { PopoverView().environmentObject(store) }
    }

    private func metricItem(_ m: Metric) -> some Scene {
        MenuBarExtra(isInserted: binding(for: m)) {
            WhenVisible { MetricDetailView(metric: m).environmentObject(store) }
        } label: {
            MetricStatusLabel(metric: m, snapshot: store.current, style: style,
                              history: showSparkline ? Array(store.history.suffix(StatusImage.sparklinePoints)) : nil)
        }
        .menuBarExtraStyle(.window)
    }

    /// Settings are the source of truth. A removal coming from the menu bar is only stored when the user
    /// is ⌘-dragging the item out; macOS also hides items on its own (no room) and that must not silently
    /// uncheck the metric in Settings. Such items are remembered in `HiddenBySystem`, so the binding
    /// agrees with the menu bar and SwiftUI doesn't keep putting the item back.
    private func binding(for m: Metric) -> Binding<Bool> {
        Binding(
            get: { MenuBarMetrics.decode(metricsRaw).contains(m) && !hiddenBySystem.metrics.contains(m) },
            set: { on in
                if !on && !NSEvent.modifierFlags.contains(.command) {
                    // SwiftUI also writes false when it removes the item because the metric got unselected;
                    // only a metric that is still selected was hidden by macOS. Deferred: SwiftUI may call
                    // this while updating scenes.
                    DispatchQueue.main.async {
                        let raw = UserDefaults.standard.string(forKey: MenuBarMetrics.key) ?? MenuBarMetrics.all
                        if MenuBarMetrics.decode(raw).contains(m) { HiddenBySystem.shared.metrics.insert(m) }
                    }
                    return
                }
                if hiddenBySystem.metrics.contains(m) { hiddenBySystem.metrics.remove(m) }
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
    /// Recent samples for the mini chart after the label; nil = no chart.
    var history: [MetricsSnapshot]? = nil

    var body: some View {
        // A MenuBarExtra label shows only one image, so label and chart are drawn into one.
        Image(nsImage: history.map { StatusImage.withSparkline(metric, snapshot, style, history: $0) }
                ?? StatusImage.render(metric, snapshot, style))
            .accessibilityLabel("\(metric.title) \(metric.valueText(snapshot))")
    }
}

/// Draws status bar items with widths computed from the widest possible value.
enum StatusImage {
    static let height: CGFloat = 22
    static let sparklineKey = "menuBarSparkline"
    /// Samples shown in the mini chart (40 s at the default 1 s interval).
    static let sparklinePoints = 40
    private static let sparklineSize = NSSize(width: 34, height: 16)

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
        // Battery: a bolt after the caption while charging; the width already counts with it.
        let label = m.title.uppercased() + (m == .battery && s.battery?.charging == true ? " ⚡︎" : "")
        let w = max(width("100%", valueFont), width(m.title.uppercased() + (m == .battery ? " ⚡︎" : ""), labelFont))
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
        let symbol = symbolImage(m, s)
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

    // MARK: Mini chart

    /// Label followed by a history chart in the metric's colors. The colored chart means the image can't be a
    /// template, so the label is tinted with `labelColor` while the image is drawn – the drawing handler runs
    /// in the status item's appearance, so the text matches the menu bar (light or dark).
    static func withSparkline(_ m: Metric, _ s: MetricsSnapshot, _ style: MenuBarStyle, history: [MetricsSnapshot]) -> NSImage {
        let label = render(m, s, style)
        let gap: CGFloat = 4
        let size = NSSize(width: label.size.width + gap + sparklineSize.width, height: height)
        let img = NSImage(size: size, flipped: false) { _ in
            let labelRect = NSRect(x: 0, y: ((height - label.size.height) / 2).rounded(),
                                   width: label.size.width, height: label.size.height)
            label.draw(in: labelRect)
            NSColor.labelColor.set()
            labelRect.fill(using: .sourceAtop)
            drawSparkline(in: NSRect(x: label.size.width + gap, y: ((height - sparklineSize.height) / 2).rounded(),
                                     width: sparklineSize.width, height: sparklineSize.height),
                          metric: m, history: history)
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func drawSparkline(in rect: NSRect, metric m: Metric, history: [MetricsSnapshot]) {
        let color = NSColor(m.inColor)
        let outColor = NSColor(m.outColor)
        // Faint frame so an idle (flat) chart is still visible on light and dark menu bars.
        NSColor.gray.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

        let primary: [Double], secondary: [Double]?
        switch m {
        case .net:
            primary = history.map(\.netIn)
            secondary = history.map(\.netOut)
        case .disk:
            primary = history.map(\.diskRead)
            secondary = history.map(\.diskWrite)
        default:
            primary = history.map { m.fraction($0) }
            secondary = nil
        }
        guard primary.count > 1 else { return }
        // Rates scale to the window's peak (at least 10 KB/s so idle noise stays flat), others are 0...1.
        let scale = m.isRateChart ? max((primary + (secondary ?? [])).max() ?? 0, 10_000) : 1

        let inner = rect.insetBy(dx: 1, dy: 1)
        // Right-aligned: the newest sample is always at the right edge, even before the window fills up.
        let step = inner.width / CGFloat(StatusImage.sparklinePoints - 1)
        func point(_ i: Int, _ v: Double, count: Int) -> NSPoint {
            let x = inner.maxX - CGFloat(count - 1 - i) * step
            let y = inner.minY + inner.height * CGFloat(min(max(v / scale, 0), 1))
            return NSPoint(x: x, y: y)
        }

        let area = NSBezierPath()
        area.move(to: NSPoint(x: point(0, 0, count: primary.count).x, y: inner.minY))
        for (i, v) in primary.enumerated() { area.line(to: point(i, v, count: primary.count)) }
        area.line(to: NSPoint(x: inner.maxX, y: inner.minY))
        area.close()
        color.withAlphaComponent(0.45).setFill()
        area.fill()

        let line = NSBezierPath()
        for (i, v) in primary.enumerated() {
            let p = point(i, v, count: primary.count)
            i == 0 ? line.move(to: p) : line.line(to: p)
        }
        line.lineWidth = 1
        line.lineJoinStyle = .round
        color.setStroke()
        line.stroke()

        // OUT / write as a separate line on top.
        if let secondary {
            let out = NSBezierPath()
            for (i, v) in secondary.enumerated() {
                let p = point(i, v, count: secondary.count)
                i == 0 ? out.move(to: p) : out.line(to: p)
            }
            out.lineWidth = 1.2
            outColor.setStroke()
            out.stroke()
        }
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

    private static func symbolImage(_ m: Metric, _ s: MetricsSnapshot) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: m.symbol(for: s), accessibilityDescription: m.title)?
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
