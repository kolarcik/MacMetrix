import SwiftUI

/// Resource Monitor window, modelled on the Windows one: every process with CPU, memory, disk and
/// network, and a network tab with per-process traffic, TCP connections and listening ports.
/// Processes selected in Přehled filter the other tab (like the checkboxes in Windows).
struct ResourceMonitorView: View {
    @StateObject private var monitor = ResourceMonitor()
    /// Kept in defaults: `WhenVisible` recreates the view whenever the window comes back on screen.
    @AppStorage("resourcesTab") private var tab: Tab = .overview
    @State private var selection = Set<Int32>()
    @State private var search = ""
    @State private var pendingEnd: EndRequest?
    @State private var error: String?

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Přehled", network = "Síť"
        var id: String { rawValue }
    }

    struct EndRequest: Identifiable {
        var pids: [Int32]
        var names: [String]
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
                    case .network:
                        NetworkTab(monitor: monitor, filter: filterPids, search: search, actions: actions)
                    }
                }
                .frame(minWidth: 560, idealWidth: 960, maxWidth: .infinity)
                .layoutPriority(1)
                ResourceGraphs()
            }
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 520)
        .background(WindowReader { monitor.window = $0 })
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .confirmationDialog(pendingEnd.map(title) ?? "", isPresented: Binding(get: { pendingEnd != nil },
                                                                              set: { if !$0 { pendingEnd = nil } }),
                            presenting: pendingEnd) { req in
            Button(req.force ? "Vynutit ukončení" : "Ukončit", role: .destructive) {
                error = ResourceMonitor.end(req.pids, force: req.force)
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
            .frame(width: 180)

            if !filterPids.isEmpty && tab != .overview {
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
            TextField("Hledat proces, PID, port…", text: $search)
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
            Text("Vláken: \(procs.reduce(0) { $0 + max($1.threads, 0) })+")
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
                let names = pids.map { pid in monitor.processes.first { $0.pid == pid }?.name ?? "pid \(pid)" }
                pendingEnd = EndRequest(pids: pids, names: names, force: force)
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
                Button("Zobrazit ve Finderu") {
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

    private func copy(_ s: String) {
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

private struct Rate: View {
    /// Bytes per second; negative = unknown.
    var value: Double

    var body: some View {
        Num(text: value < 0 ? "–" : value < 1 ? "0" : Fmt.rate(value), zero: value < 1)
            .help(value < 0 ? "Systém údaj o procesu jiného uživatele nesdělí." : Fmt.rate(value))
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
