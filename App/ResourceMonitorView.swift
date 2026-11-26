import SwiftUI

/// Resource Monitor window, modelled on the Windows one: every process with CPU, memory, disk and
/// network; a memory tab with footprints and the RAM composition; a network tab with per-process
/// traffic, TCP connections and listening ports; and a files tab showing who holds which file open.
/// Processes selected in Přehled or Paměť filter the Síť and Soubory tabs (like the checkboxes in Windows).
/// On the right, graphs of CPU (total and every core), memory, disk, network and GPU – this window
/// replaced the old dashboard.
struct ResourceMonitorView: View {
    @StateObject private var monitor = ResourceMonitor()
    /// Kept in defaults: `WhenVisible` recreates the view whenever the window comes back on screen.
    @AppStorage("resourcesTab") private var tab: Tab = .overview
    @State private var selection = Set<Int32>()
    @State private var search = ""
    @State private var pendingEnd: EndRequest?
    @State private var error: String?

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Přehled", memory = "Paměť", network = "Síť", files = "Soubory"
        var id: String { rawValue }
        /// Tabs whose tables are filtered by the processes selected elsewhere.
        var isFiltered: Bool { self == .network || self == .files }
    }

    struct EndRequest: Identifiable {
        var pids: [Int32]
        var names: [String]
        /// Executables at the time the user asked, to detect a pid reused before confirming.
        var paths: [Int32: String]
        var force: Bool
        var id: String { "\(force)|\(pids)" }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                Group {
                    switch tab {
                    case .overview:
                        ProcessesTable(rows: filteredProcesses, selection: $selection, actions: actions)
                    case .memory:
                        MemoryTab(rows: filteredProcesses, selection: $selection, actions: actions)
                    case .network:
                        NetworkTab(monitor: monitor, filter: filterPids, search: search, actions: actions)
                    case .files:
                        FilesTab(files: monitor.files, filter: filterPids, search: search, actions: actions,
                                 allProcesses: monitor.helperActive)
                    }
                }
                .frame(minWidth: 560, idealWidth: 960, maxWidth: .infinity)
                .layoutPriority(1)
                ResourceGraphs {
                    if filterPids.count == 1, let pid = filterPids.first {
                        ProcessGraphs(monitor: monitor, pid: pid)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 520)
        .background(WindowReader { monitor.window = $0 })
        .onAppear {
            monitor.start()
            monitor.collectFiles = tab == .files
        }
        .onChange(of: tab) { _, new in monitor.collectFiles = new == .files }
        .onDisappear { monitor.stop() }
        .confirmationDialog(pendingEnd.map(title) ?? "", isPresented: Binding(get: { pendingEnd != nil },
                                                                              set: { if !$0 { pendingEnd = nil } }),
                            presenting: pendingEnd) { req in
            Button(req.force ? "Vynutit ukončení" : "Ukončit", role: .destructive) {
                error = ResourceMonitor.end(req.pids, paths: req.paths, force: req.force)
            }
            Button("Zrušit", role: .cancel) {}
        } message: { req in
            Text(req.force ? "Neuložená data v procesu se ztratí." : "Aplikace dostanou možnost uložit data a skončit samy.")
        }
        .alert("Proces se nepodařilo ukončit", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func title(_ req: EndRequest) -> String {
        let what = req.names.count == 1 ? "„\(req.names[0])“" : "\(req.names.count) procesy"
        return (req.force ? "Vynutit ukončení " : "Ukončit ") + what + "?"
    }

    // MARK: Header & footer

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)

            if !filterPids.isEmpty && tab.isFiltered {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.tint)
                    Text("Jen: " + filterNames).lineLimit(1).truncationMode(.tail)
                    Button {
                        selection.removeAll()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Zrušit filtr")
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .frame(maxWidth: 320, alignment: .leading)
            }
            Spacer()
            TextField(tab == .files ? "Hledat cestu nebo proces…" : "Hledat proces, PID, port…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        let procs = monitor.processes
        let cpu = procs.reduce(0) { $0 + $1.cpu }
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        return HStack(spacing: 16) {
            Text("Procesů: \(procs.count)")
            (Text("Vláken: \(procs.reduce(0) { $0 + max($1.threads, 0) })") + Text(procs.contains { $0.threads < 0 } ? "+" : ""))
                .help("Jen procesy přihlášeného uživatele – u ostatních systém počet vláken nesdělí.")
            Text("CPU: \(Int((cpu / cores).rounded())) %")
            Text("TCP spojení: \(monitor.connections.count)")
            Text("Naslouchajících portů: \(monitor.listening.count)")
            Spacer()
            if !selection.isEmpty {
                Text("Vybráno: \(selection.count)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: Filtering

    /// Selected processes that still exist.
    private var filterPids: Set<Int32> {
        selection.intersection(monitor.processes.map(\.pid))
    }

    private var filterNames: String {
        monitor.processes.filter { filterPids.contains($0.pid) }.map(\.name).joined(separator: ", ")
    }

    private var filteredProcesses: [ProcessRow] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return monitor.processes }
        return monitor.processes.filter {
            $0.name.localizedCaseInsensitiveContains(q) || String($0.pid) == q || $0.user.localizedCaseInsensitiveContains(q)
                || ($0.path?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    // MARK: Actions

    private var actions: ProcessActions {
        ProcessActions(
            processes: monitor.processes,
            end: { pids, force in
                let rows = pids.compactMap { pid in monitor.processes.first { $0.pid == pid } }
                let names = pids.map { pid in rows.first { $0.pid == pid }?.name ?? "pid \(pid)" }
                let paths = Dictionary(rows.compactMap { r in r.path.map { (r.pid, $0) } }, uniquingKeysWith: { a, _ in a })
                pendingEnd = EndRequest(pids: pids, names: names, paths: paths, force: force)
            },
            showInNetwork: { pids in
                selection = Set(pids)
                tab = .network
            })
    }
}

/// Context menu shared by all tables.
struct ProcessActions {
    var processes: [ProcessRow]
    var end: ([Int32], Bool) -> Void
    var showInNetwork: ([Int32]) -> Void

    @ViewBuilder
    func menu(_ pids: Set<Int32>, network: Bool = false) -> some View {
        let pids = pids.sorted()
        let rows = processes.filter { pids.contains($0.pid) }
        if !pids.isEmpty {
            Button(pids.count == 1 ? "Ukončit proces" : "Ukončit \(pids.count) procesy") { end(pids, false) }
            Button("Vynutit ukončení") { end(pids, true) }
            Divider()
            if !network {
                Button("Zobrazit síťovou aktivitu") { showInNetwork(pids) }
            }
            if let path = rows.first?.path, rows.count == 1 {
                Button("Zobrazit program ve Finderu") {
                    NSWorkspace.shared.activateFileViewerSelecting([Self.revealURL(path)])
                }
                Button("Kopírovat cestu") { copy(path) }
            }
            Button("Kopírovat PID") { copy(pids.map(String.init).joined(separator: " ")) }
        }
    }

    /// For an executable inside an app bundle, select the app itself.
    private static func revealURL(_ path: String) -> URL {
        if let r = path.range(of: ".app/Contents/MacOS/") {
            return URL(fileURLWithPath: String(path[..<r.lowerBound]) + ".app")
        }
        return URL(fileURLWithPath: path)
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Přehled

private struct ProcessesTable: View {
    var rows: [ProcessRow]
    @Binding var selection: Set<Int32>
    var actions: ProcessActions
    @State private var sort = [KeyPathComparator(\ProcessRow.cpu, order: .reverse)]

    var body: some View {
        Table(rows.sorted(using: sort), selection: $selection, sortOrder: $sort) {
            TableColumn("Proces", value: \.name) { r in
                ProcessName(pid: r.pid, name: r.name).help(r.path ?? r.name)
            }
            .width(min: 140, ideal: 180)
            TableColumn("PID", value: \.pid) { r in Text(String(r.pid)).monospacedDigit() }
                .width(min: 44, ideal: 52)
            TableColumn("Uživatel", value: \.user) { r in Text(r.user).foregroundStyle(.secondary) }
                .width(min: 50, ideal: 70)
            TableColumn("CPU %", value: \.cpu) { r in Num(text: String(format: "%.1f", r.cpu), zero: r.cpu < 0.05) }
                .width(min: 62, ideal: 68)
            TableColumn("Vlákna", value: \.threads) { r in Num(text: r.threads < 0 ? "–" : String(r.threads), zero: r.threads < 0) }
                .width(min: 44, ideal: 52)
            TableColumn("Paměť", value: \.memory) { r in Num(text: Fmt.bytes(r.memory), zero: false) }
                .width(min: 60, ideal: 76)
            TableColumn("Disk čtení", value: \.diskRead) { r in Rate(value: r.diskRead) }
                .width(min: 60, ideal: 76)
            TableColumn("Disk zápis", value: \.diskWrite) { r in Rate(value: r.diskWrite) }
                .width(min: 60, ideal: 76)
            TableColumn("Síť ↓", value: \.netIn) { r in Rate(value: r.netIn) }
                .width(min: 60, ideal: 76)
            TableColumn("Síť ↑", value: \.netOut) { r in Rate(value: r.netOut) }
                .width(min: 60, ideal: 76)
        }
        .contextMenu(forSelectionType: Int32.self) { pids in actions.menu(pids) }
    }
}

// MARK: - Paměť

private struct MemoryTab: View {
    var rows: [ProcessRow]
    @Binding var selection: Set<Int32>
    var actions: ProcessActions
    @State private var sort = [KeyPathComparator(\ProcessRow.footprint, order: .reverse)]

    var body: some View {
        VStack(spacing: 0) {
            MemorySummary()
            Divider()
            Table(rows.sorted(using: sort), selection: $selection, sortOrder: $sort) {
                TableColumn("Proces", value: \.name) { r in ProcessName(pid: r.pid, name: r.name).help(r.path ?? r.name) }
                    .width(min: 140, ideal: 200)
                TableColumn("PID", value: \.pid) { r in Text(String(r.pid)).monospacedDigit() }
                    .width(min: 44, ideal: 52)
                TableColumn("Uživatel", value: \.user) { r in Text(r.user).foregroundStyle(.secondary) }
                    .width(min: 50, ideal: 70)
                TableColumn("Paměť", value: \.footprint) { r in Bytes(value: r.footprint) }
                    .width(min: 64, ideal: 80)
                TableColumn("Špička", value: \.maxFootprint) { r in Bytes(value: r.maxFootprint) }
                    .width(min: 64, ideal: 80)
                TableColumn("Rezidentní", value: \.memory) { r in Bytes(value: Int64(r.memory)) }
                    .width(min: 64, ideal: 80)
                TableColumn("Načteno z disku/s", value: \.pageins) { r in
                    Num(text: r.pageins < 0 ? "–" : String(Int(r.pageins.rounded())), zero: r.pageins < 0.5)
                        .help("Stránky načtené z disku (page-ins) – obdoba tvrdých chyb stránky ve Windows.")
                }
                .width(min: 70, ideal: 110)
                TableColumn("Vlákna", value: \.threads) { r in Num(text: r.threads < 0 ? "–" : String(r.threads), zero: r.threads < 0) }
                    .width(min: 44, ideal: 52)
            }
            .contextMenu(forSelectionType: Int32.self) { pids in actions.menu(pids) }
        }
    }
}

/// Composition of physical memory as a stacked bar with a legend, like the Memory tab in Windows.
/// Observes the store on its own, so the table below doesn't redraw every second.
private struct MemorySummary: View {
    @EnvironmentObject var store: MonitorStore

    var body: some View {
        let s = store.current
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Fyzická paměť").font(.headline)
                Text("\(Fmt.gb(s.memUsed)) použito z \(Fmt.gb(s.memTotal))").foregroundStyle(.secondary)
                Spacer()
                Text("Tlak paměti:").foregroundStyle(.secondary)
                Text(pressure.0).foregroundStyle(pressure.1).fontWeight(.medium)
                Text("· Swap \(Fmt.gb(s.swapUsed))").foregroundStyle(.secondary)
            }
            .monospacedDigit()
            MemoryBar(s: s).frame(height: 18)
            HStack(spacing: 14) {
                legend("Aplikace", s.memApp ?? 0, .orange)
                legend("Pevně alokovaná", s.memWired, .yellow)
                legend("Komprimovaná", s.memCompressed, .purple)
                legend("Mezipaměť souborů", s.memCached ?? 0, .blue.opacity(0.6))
                legend("Volná", s.memFree ?? 0, .gray.opacity(0.5))
            }
            .font(.caption)
        }
        .padding(12)
    }

    private var pressure: (String, Color) {
        switch store.current.memPressure {
        case 2: ("Zvýšený", .yellow)
        case 4: ("Kritický", .red)
        case 1: ("Normální", .green)
        default: ("–", .secondary)
        }
    }

    private func legend(_ title: String, _ bytes: UInt64, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title).foregroundStyle(.secondary)
            Text(Fmt.gb(bytes)).monospacedDigit()
        }
    }
}

// MARK: - Soubory

private struct FilesTab: View {
    var files: [OpenFile]
    var filter: Set<Int32>
    var search: String
    var actions: ProcessActions
    /// Files of all processes (privileged helper), not just the current user's.
    var allProcesses: Bool
    @State private var sort = [KeyPathComparator(\OpenFile.path)]
    @State private var selection = Set<String>()

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespaces)
        if filter.isEmpty && query.isEmpty {
            ContentUnavailableView {
                Label("Otevřené soubory", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Vyberte proces v Přehledu nebo zadejte do hledání část cesty.\nNapříklad /Volumes/USB ukáže, kdo brání vysunutí disku.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let rows = files.filter { f in
                (filter.isEmpty || filter.contains(f.pid))
                    && (query.isEmpty || f.path.localizedCaseInsensitiveContains(query)
                        || f.name.localizedCaseInsensitiveContains(query) || String(f.pid) == query)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Otevřené soubory").font(.headline)
                    Text(verbatim: String(rows.count)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if !allProcesses {
                        Text("Jen procesy přihlášeného uživatele – ostatní doplní Nastavení → Údaje o systémových procesech")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Table(rows.sorted(using: sort), selection: $selection, sortOrder: $sort) {
                    TableColumn("Proces", value: \.name) { f in ProcessName(pid: f.pid, name: f.name) }
                        .width(min: 120, ideal: 170)
                    TableColumn("PID", value: \.pid) { f in Text(String(f.pid)).monospacedDigit() }
                        .width(min: 44, ideal: 52)
                    TableColumn("Typ", value: \.kindName) { f in Text(f.kindName).foregroundStyle(.secondary) }
                        .width(min: 50, ideal: 70)
                    TableColumn("Režim", value: \.mode) { f in Text(f.mode).foregroundStyle(.secondary) }
                        .width(min: 50, ideal: 80)
                    TableColumn("Cesta", value: \.path) { f in
                        Text(verbatim: f.path).lineLimit(1).truncationMode(.middle).help(f.path)
                    }
                    .width(min: 200, ideal: 480)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    let picked = rows.filter { ids.contains($0.id) }
                    if let file = picked.first, picked.count == 1 {
                        Button("Zobrazit soubor ve Finderu") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                        }
                        Button("Kopírovat cestu souboru") { actions.copy(file.path) }
                        Divider()
                    }
                    actions.menu(Set(picked.map(\.pid)))
                }
            }
        }
    }
}

// MARK: - Síť

private struct NetworkTab: View {
    @ObservedObject var monitor: ResourceMonitor
    var filter: Set<Int32>
    var search: String
    var actions: ProcessActions
    @State private var procSort = [KeyPathComparator(\ProcessRow.net, order: .reverse)]
    @State private var connSort = [KeyPathComparator(\NetConnection.rateIn, order: .reverse)]
    @State private var portSort = [KeyPathComparator(\ListeningPort.port)]

    var body: some View {
        VSplitView {
            section("Procesy se síťovou aktivitou", count: activeProcesses.count) {
                Table(activeProcesses.sorted(using: procSort), sortOrder: $procSort) {
                    TableColumn("Proces", value: \.name) { r in ProcessName(pid: r.pid, name: r.name) }
                        .width(min: 140, ideal: 220)
                    TableColumn("PID", value: \.pid) { r in Text(String(r.pid)).monospacedDigit() }
                        .width(min: 44, ideal: 56)
                    TableColumn("Přijato ↓", value: \.netIn) { r in Rate(value: r.netIn) }
                    TableColumn("Odesláno ↑", value: \.netOut) { r in Rate(value: r.netOut) }
                    TableColumn("Celkem", value: \.net) { r in Rate(value: r.net) }
                }
                .contextMenu(forSelectionType: Int32.self) { pids in actions.menu(pids, network: true) }
            }
            section("TCP spojení", count: connections.count) {
                Table(connections.sorted(using: connSort), sortOrder: $connSort) {
                    TableColumn("Proces", value: \.name) { c in ProcessName(pid: c.pid, name: c.name) }
                        .width(min: 120, ideal: 170)
                    TableColumn("PID", value: \.pid) { c in Text(String(c.pid)).monospacedDigit() }
                        .width(min: 44, ideal: 56)
                    TableColumn("Místní adresa", value: \.localAddress) { c in Addr(host: c.localAddress, port: c.localPort) }
                        .width(min: 100, ideal: 150)
                    TableColumn("Vzdálená adresa", value: \.remoteAddress) { c in Addr(host: c.remoteAddress, port: c.remotePort) }
                        .width(min: 100, ideal: 170)
                    TableColumn("Stav", value: \.state) { c in Text(c.state).foregroundStyle(c.state == "Navázáno" ? .primary : .secondary) }
                        .width(min: 70, ideal: 100)
                    TableColumn("↓", value: \.rateIn) { c in Rate(value: c.rateIn) }
                        .width(min: 54, ideal: 70)
                    TableColumn("↑", value: \.rateOut) { c in Rate(value: c.rateOut) }
                        .width(min: 54, ideal: 70)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    actions.menu(Set(connections.filter { ids.contains($0.id) }.map(\.pid)), network: true)
                }
            }
            section("Naslouchající porty", count: ports.count) {
                Table(ports.sorted(using: portSort), sortOrder: $portSort) {
                    TableColumn("Proces", value: \.name) { p in ProcessName(pid: p.pid, name: p.name) }
                        .width(min: 120, ideal: 200)
                    TableColumn("PID", value: \.pid) { p in Text(String(p.pid)).monospacedDigit() }
                        .width(min: 44, ideal: 56)
                    TableColumn("Port", value: \.port) { p in Text(String(p.port)).monospacedDigit().fontWeight(.medium) }
                        .width(min: 44, ideal: 60)
                    TableColumn("Protokol", value: \.proto)
                        .width(min: 50, ideal: 60)
                    TableColumn("Adresa", value: \.addresses) { p in Text(p.addresses).foregroundStyle(.secondary) }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    actions.menu(Set(ports.filter { ids.contains($0.id) }.map(\.pid)), network: true)
                }
            }
        }
    }

    private func section(_ title: String, count: Int, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Text(verbatim: String(count)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            content()
        }
        .frame(minHeight: 110)
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private func matches(_ pid: Int32, _ texts: String...) -> Bool {
        if !filter.isEmpty && !filter.contains(pid) { return false }
        guard !query.isEmpty else { return true }
        return String(pid) == query || texts.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private var activeProcesses: [ProcessRow] {
        monitor.processes.filter { ($0.net > 0 || filter.contains($0.pid)) && matches($0.pid, $0.name) }
    }

    private var connections: [NetConnection] {
        monitor.connections.filter {
            matches($0.pid, $0.name, $0.localAddress, $0.remoteAddress, String($0.localPort), String($0.remotePort))
        }
    }

    private var ports: [ListeningPort] {
        monitor.listening.filter { matches($0.pid, $0.name, String($0.port), $0.addresses) }
    }
}

// MARK: - Cells

private struct ProcessName: View {
    var pid: Int32
    var name: String

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: ProcessIcon.image(pid, name: name))
                .resizable()
                .frame(width: 16, height: 16)
            Text(name).lineLimit(1)
        }
    }
}

/// Right-aligned number; zero / unknown values are dimmed so active processes stand out.
private struct Num: View {
    var text: String
    var zero: Bool

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(zero ? .tertiary : .primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Byte count; negative = unknown.
private struct Bytes: View {
    var value: Int64

    var body: some View {
        Num(text: value < 0 ? "–" : Fmt.bytes(UInt64(value)), zero: value < 0)
            .help(value < 0 ? "Systém údaj o procesu jiného uživatele nesdělí. Doplní ho Nastavení → Údaje o systémových procesech." : "")
    }
}

private struct Rate: View {
    /// Bytes per second; negative = unknown.
    var value: Double

    var body: some View {
        Num(text: value < 0 ? "–" : value < 1 ? "0" : Fmt.rate(value), zero: value < 1)
            .help(value < 0 ? "Systém údaj o procesu jiného uživatele nesdělí. Doplní ho Nastavení → Údaje o systémových procesech." : Fmt.rate(value))
    }
}

private struct Addr: View {
    var host: String
    var port: Int

    var body: some View {
        (Text(verbatim: host) + Text(verbatim: port > 0 ? ":\(port)" : "").foregroundStyle(.secondary))
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
            .help(port > 0 ? "\(host):\(port)" : host)
    }
}
