import SwiftUI

/// Content of the separate "Nastavení" window.
struct SettingsView: View {
    @EnvironmentObject var store: MonitorStore
    @AppStorage("menuBarStyle") private var style: MenuBarStyle = .stacked
    @AppStorage(MenuBarMetrics.key) private var metricsRaw = MenuBarMetrics.all

    private func metricBinding(_ m: Metric) -> Binding<Bool> {
        Binding(
            get: { MenuBarMetrics.decode(metricsRaw).contains(m) },
            set: { on in
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
                ForEach(Metric.allCases) { m in
                    Toggle(isOn: metricBinding(m)) {
                        Label(m.longTitle, systemImage: m.symbol)
                    }
                }
                Picker("Vzhled ukazatelů", selection: $style) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Ukazatele ve stavové liště")
            } footer: {
                Text(MenuBarMetrics.decode(metricsRaw).isEmpty
                     ? "Nic nevybráno – ve stavové liště bude jen ikona aplikace."
                     : "Pořadí ukazatelů změníš přetažením se stisknutým ⌘.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
