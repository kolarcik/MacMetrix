import SwiftUI

/// Content of the separate "Nastavení" window.
struct SettingsView: View {
    @EnvironmentObject var store: MonitorStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarStyle") private var style: MenuBarStyle = .stacked
    @AppStorage(MenuBarMetrics.key) private var metricsRaw = MenuBarMetrics.all
    @AppStorage(StatusImage.sparklineKey) private var showSparkline = false
    @AppStorage(AppTheme.key) private var theme: AppTheme = .system
    @ObservedObject private var helper = PrivilegedHelper.shared

    private func metricBinding(_ m: Metric) -> Binding<Bool> {
        Binding(
            get: { MenuBarMetrics.decode(metricsRaw).contains(m) },
            set: { on in
                HiddenBySystem.shared.metrics.remove(m) // switching it on again retries an item macOS hid
                var list = MenuBarMetrics.decode(metricsRaw).filter { $0 != m }
                if on { list.append(m) }
                metricsRaw = MenuBarMetrics.encode(Metric.allCases.filter(list.contains))
            })
    }

    var body: some View {
        Form {
            Section("Obecné") {
                Toggle("Spouštět po přihlášení", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }))
                if let err = store.loginItemError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Picker("Motiv", selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: theme) { _, new in new.apply() }
                Picker("Interval měření", selection: Binding(
                    get: { store.sampleInterval },
                    set: { store.sampleInterval = $0 })) {
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("5 s").tag(5.0)
                }
                .pickerStyle(.segmented)
                Picker("Obnovení widgetu", selection: $store.widgetInterval) {
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                    Text("30 s").tag(30.0)
                    Text("1 min").tag(60.0)
                }
                .pickerStyle(.segmented)
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    LabeledContent("Widget naposledy obnoven") {
                        if let d = SharedStore.lastWidgetReload() {
                            Text(d, format: .dateTime.hour().minute().second())
                        } else {
                            Text("zatím ne – přidej widget na plochu")
                        }
                    }
                }
            }

            Section {
                ForEach(Metric.available) { m in
                    Toggle(isOn: metricBinding(m)) {
                        Label(m.longTitle, systemImage: m.symbol)
                    }
                }
                Picker("Vzhled ukazatelů", selection: $style) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $showSparkline) {
                    Text("Miniatura grafu za ukazatelem")
                    Text("Posledních \(StatusImage.sparklinePoints) měření; v barvách metrik, u sítě IN modře a OUT červeně, u disku čtení růžově a zápis fialově.")
                }
            } header: {
                Text("Ukazatele ve stavové liště")
            } footer: {
                Text(MenuBarMetrics.decode(metricsRaw).isEmpty
                     ? String(localized: "Nic nevybráno – ve stavové liště bude jen ikona aplikace.")
                     : String(localized: "Pořadí ukazatelů změníš přetažením se stisknutým ⌘.")
                        + (Metric.available.contains(.battery)
                           ? " " + String(localized: "Baterie má vždy vlastní ikonu s procentem, bez miniatury grafu.") : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Binding(get: { helper.isOn }, set: { helper.setEnabled($0) })) {
                    Text("Údaje o systémových procesech")
                    Text("Doplní vlákna, paměť, disk a otevřené soubory i u procesů systému a jiných uživatelů. Zapne pomocnou službu na pozadí s právy správce, která jen čte – nic nemění ani neukončuje. Ve výchozím stavu je vypnuto.")
                }
                switch helper.isOn ? helper.status : .notRegistered {
                case .enabled:
                    Text("Služba je schválená a Monitor prostředků ji používá.")
                        .font(.caption).foregroundStyle(.secondary)
                case .requiresApproval:
                    HStack {
                        Text("Čeká na schválení v Nastavení systému → Obecné → Položky při přihlášení.")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Otevřít…") { helper.openSystemSettings() }
                    }
                case .notFound:
                    Text("Pomocná služba v aplikaci chybí – nainstalujte MacMetrix znovu.")
                        .font(.caption).foregroundStyle(.red)
                default:
                    EmptyView()
                }
                if let err = helper.error {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Monitor prostředků")
            }
            .onAppear { helper.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                helper.refresh() // back from System Settings after approving
            }

            Section {
                Button("O aplikaci MacMetrix…") { openWindow(id: "about") }
                    .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        // The form scrolls; the window can be made taller, but starts at a height that fits most screens.
        .frame(width: 440)
        .frame(minHeight: 320, idealHeight: 640)
    }
}
