import AppKit

/// A group of files the cleanup wizard can remove.
struct CleanupCategory: Identifiable {
    enum Source {
        /// Everything inside these directories (the directories themselves stay).
        case contents([String])
        /// Items inside these directories not modified for `days` days.
        case olderThan([String], days: Int)
        /// `bin`/`obj` next to .NET project files and `.build` next to Package.swift under the chosen folder.
        case projectOutputs
        /// Simulators whose runtime is no longer installed (`xcrun simctl delete unavailable`).
        case unavailableSimulators
    }

    var id: String
    var title: String
    var detail: String
    var symbol: String
    var source: Source
    var selectedByDefault: Bool

    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static let all: [CleanupCategory] = [
        .init(id: "derived", title: "Xcode – DerivedData", detail: "Mezivýsledky buildů. Xcode je při dalším buildu vytvoří znovu.",
              symbol: "hammer", source: .contents(["~/Library/Developer/Xcode/DerivedData"]), selectedByDefault: true),
        .init(id: "archives", title: "Xcode – archivy", detail: "Archivy aplikací včetně dSYM. Smaž jen, pokud je nepotřebuješ k symbolikaci pádů.",
              symbol: "archivebox", source: .contents(["~/Library/Developer/Xcode/Archives"]), selectedByDefault: false),
        .init(id: "devicesupport", title: "Xcode – podpora zařízení", detail: "Symboly pro ladění na fyzických zařízeních. Po připojení zařízení se stáhnou znovu.",
              symbol: "iphone", source: .contents([
                  "~/Library/Developer/Xcode/iOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport",
                  "~/Library/Developer/Xcode/tvOS DeviceSupport", "~/Library/Developer/Xcode/visionOS DeviceSupport",
              ]), selectedByDefault: true),
        .init(id: "previews", title: "Xcode – SwiftUI Previews", detail: "Cache náhledů SwiftUI.",
              symbol: "eye", source: .contents(["~/Library/Developer/Xcode/UserData/Previews"]), selectedByDefault: true),
        .init(id: "simcaches", title: "Simulátory – cache", detail: "Dočasná data CoreSimulatoru.",
              symbol: "ipad.and.iphone", source: .contents(["~/Library/Developer/CoreSimulator/Caches"]), selectedByDefault: true),
        .init(id: "simunavailable", title: "Nedostupné simulátory", detail: "Simulátory pro verze iOS, které už nejsou nainstalované. Mažou se vždy trvale.",
              symbol: "xmark.app", source: .unavailableSimulators, selectedByDefault: true),
        .init(id: "spm", title: "Swift Package Manager", detail: "Stažené balíčky a repozitáře SPM.",
              symbol: "shippingbox", source: .contents(["~/Library/Caches/org.swift.swiftpm"]), selectedByDefault: true),
        .init(id: "pods", title: "CocoaPods / Carthage", detail: "Cache stažených podů a frameworků.",
              symbol: "shippingbox.fill", source: .contents(["~/Library/Caches/CocoaPods", "~/Library/Caches/org.carthage.CarthageKit"]),
              selectedByDefault: true),
        .init(id: "projects", title: "Build výstupy projektů", detail: "Složky bin/obj (.NET) a .build (Swift) v projektech.",
              symbol: "folder.badge.gearshape", source: .projectOutputs, selectedByDefault: true),
        .init(id: "nugethttp", title: ".NET – NuGet cache", detail: "HTTP a plugin cache NuGetu.",
              symbol: "network", source: .contents([
                  "~/.local/share/NuGet/http-cache", "~/.local/share/NuGet/v3-cache", "~/.local/share/NuGet/plugins-cache",
              ]), selectedByDefault: true),
        .init(id: "nugetpackages", title: ".NET – NuGet balíčky", detail: "Globální složka balíčků (~/.nuget/packages). Při dalším restore se stáhnou znovu.",
              symbol: "cube.box", source: .contents(["~/.nuget/packages"]), selectedByDefault: false),
        .init(id: "gradle", title: "Gradle cache", detail: "Cache závislostí a buildů Gradle (Android).",
              symbol: "cube", source: .contents(["~/.gradle/caches"]), selectedByDefault: false),
        .init(id: "node", title: "npm / Yarn cache", detail: "Cache stažených JavaScriptových balíčků.",
              symbol: "curlybraces", source: .contents(["~/.npm/_cacache", "~/Library/Caches/Yarn"]), selectedByDefault: true),
        .init(id: "brew", title: "Homebrew cache", detail: "Stažené instalační balíčky Homebrew.",
              symbol: "mug", source: .contents(["~/Library/Caches/Homebrew"]), selectedByDefault: true),
        .init(id: "temp", title: "Dočasné soubory", detail: "Položky v dočasné složce uživatele starší než 3 dny.",
              symbol: "clock.arrow.circlepath", source: .olderThan([NSTemporaryDirectory()], days: 3), selectedByDefault: true),
        .init(id: "logs", title: "Logy", detail: "Logy aplikací a hlášení o pádech starší než 7 dní.",
              symbol: "doc.text", source: .olderThan(["~/Library/Logs"], days: 7), selectedByDefault: true),
        .init(id: "trash", title: "Koš", detail: "Obsah Koše. Maže se vždy trvale.",
              symbol: "trash", source: .contents(["~/.Trash"]), selectedByDefault: false),
    ]
}

@MainActor
final class DiskCleanupModel: ObservableObject {
    enum Phase: Equatable { case intro, scanning, review, cleaning, done }

    struct Result: Identifiable {
        var category: CleanupCategory
        var items: [(url: URL, size: UInt64)] = []
        var selected = false
        var id: String { category.id }
        var size: UInt64 { items.reduce(0) { $0 + $1.size } }
    }

    @Published var phase: Phase = .intro
    @Published var progress = 0.0
    @Published var status = ""
    @Published var results: [Result] = []
    @Published var moveToTrash = false
    @Published var freed: UInt64 = 0
    @Published var failures = 0
    @Published var projectsRoot: URL? {
        didSet { UserDefaults.standard.set(projectsRoot?.path, forKey: "cleanupProjectsRoot") }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "cleanupProjectsRoot") {
            projectsRoot = URL(fileURLWithPath: saved)
        } else {
            let develop = URL(fileURLWithPath: CleanupCategory.home).appendingPathComponent("Develop")
            projectsRoot = FileManager.default.fileExists(atPath: develop.path) ? develop : nil
        }
    }

    var selectedSize: UInt64 { results.filter(\.selected).reduce(0) { $0 + $1.size } }
    var isXcodeRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").isEmpty }

    func scan() {
        phase = .scanning
        progress = 0
        results = []
        let categories = CleanupCategory.all
        let root = projectsRoot
        Task.detached(priority: .userInitiated) {
            var found: [Result] = []
            for (i, c) in categories.enumerated() {
                await MainActor.run {
                    self.status = c.title
                    self.progress = Double(i) / Double(categories.count)
                }
                let items = Self.items(for: c.source, projectsRoot: root)
                found.append(Result(category: c, items: items, selected: c.selectedByDefault && items.reduce(0) { $0 + $1.size } > 0))
            }
            await MainActor.run {
                self.results = found
                self.progress = 1
                self.phase = .review
            }
        }
    }

    func clean() {
        phase = .cleaning
        progress = 0
        freed = 0
        failures = 0
        let selected = results.filter(\.selected)
        let toTrash = moveToTrash
        let total = Double(max(selected.reduce(0) { $0 + $1.items.count }, 1))
        Task.detached(priority: .userInitiated) {
            var done = 0.0, freed: UInt64 = 0, failures = 0
            for r in selected {
                await MainActor.run { self.status = r.category.title }
                if case .unavailableSimulators = r.category.source {
                    if Self.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"]) != nil { freed += r.size } else { failures += 1 }
                    done += Double(r.items.count)
                    continue
                }
                // Items already in the Trash can only be removed for good.
                let trashThis = toTrash && r.category.id != "trash"
                for item in r.items {
                    do {
                        if trashThis {
                            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                        } else {
                            try FileManager.default.removeItem(at: item.url)
                        }
                        freed += item.size
                    } catch {
                        failures += 1
                    }
                    done += 1
                    if Int(done) % 20 == 0 {
                        let p = done / total
                        await MainActor.run { self.progress = p }
                    }
                }
            }
            await MainActor.run {
                self.freed = freed
                self.failures = failures
                self.progress = 1
                self.phase = .done
            }
        }
    }

    func chooseProjectsRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Vybrat"
        panel.message = "Složka s projekty, ve které se hledají build výstupy (bin, obj, .build)"
        panel.directoryURL = projectsRoot
        if panel.runModal() == .OK { projectsRoot = panel.url }
    }

    func reveal(_ r: Result) {
        let urls = r.items.prefix(50).map(\.url)
        if urls.isEmpty { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Scanning (background)

    nonisolated private static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    nonisolated private static func items(for source: CleanupCategory.Source, projectsRoot: URL?) -> [(url: URL, size: UInt64)] {
        let fm = FileManager.default
        switch source {
        case .contents(let paths):
            return paths.flatMap { p -> [(URL, UInt64)] in
                let children = (try? fm.contentsOfDirectory(at: expand(p), includingPropertiesForKeys: nil)) ?? []
                return children.map { ($0, allocatedSize($0)) }
            }
            .filter { $0.0.lastPathComponent != ".DS_Store" }
            .map { (url: $0.0, size: $0.1) }

        case .olderThan(let paths, let days):
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            return paths.flatMap { p -> [(url: URL, size: UInt64)] in
                let children = (try? fm.contentsOfDirectory(at: expand(p), includingPropertiesForKeys: nil)) ?? []
                return children.compactMap { url in
                    // A directory's own mtime only changes with its direct entries, so look at everything inside.
                    guard let newest = newestModification(url), newest < cutoff else { return nil }
                    return (url, allocatedSize(url))
                }
            }

        case .projectOutputs:
            guard let root = projectsRoot else { return [] }
            return projectOutputs(in: root).map { (url: $0, size: allocatedSize($0)) }.filter { $0.size > 0 }

        case .unavailableSimulators:
            // Without Xcode, xcrun would pop up the Command Line Tools installer.
            guard run("/usr/bin/xcode-select", ["-p"]) != nil,
                  let json = run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"]),
                  let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let devices = obj["devices"] as? [String: [[String: Any]]] else { return [] }
            let base = expand("~/Library/Developer/CoreSimulator/Devices")
            return devices.values.flatMap { $0 }.compactMap { d in
                guard let udid = d["udid"] as? String else { return nil }
                let url = base.appendingPathComponent(udid)
                return (url, allocatedSize(url))
            }
        }
    }

    /// Finds build output folders: bin/obj next to *.csproj / *.fsproj / *.vbproj, .build next to Package.swift.
    nonisolated private static func projectOutputs(in root: URL) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        let skip: Set<String> = ["node_modules", ".git", "Pods", "DerivedData"]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) else {
            return []
        }
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let name = url.lastPathComponent
            if e.level > 8 || skip.contains(name) { e.skipDescendants(); continue }
            let parent = url.deletingLastPathComponent()
            if name == "bin" || name == "obj" {
                let siblings = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
                if siblings.contains(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") || $0.hasSuffix(".vbproj") }) {
                    result.append(url)
                    e.skipDescendants()
                }
            } else if name == ".build", fm.fileExists(atPath: parent.appendingPathComponent("Package.swift").path) {
                result.append(url)
                e.skipDescendants()
            } else if name.hasPrefix(".") {
                e.skipDescendants()
            }
        }
        return result
    }

    /// Newest modification date of an item and everything inside it.
    /// nil when it contains a socket / pipe (likely used by a running process) or can't be read.
    nonisolated private static func newestModification(_ url: URL) -> Date? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileResourceTypeKey]
        func check(_ u: URL, _ newest: inout Date) -> Bool {
            guard let v = try? u.resourceValues(forKeys: keys) else { return false }
            if v.fileResourceType == .socket || v.fileResourceType == .namedPipe { return false }
            if let d = v.contentModificationDate, d > newest { newest = d }
            return true
        }
        var newest = Date.distantPast
        guard check(url, &newest) else { return nil }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                     errorHandler: { _, _ in true }) else { return newest }
        for case let f as URL in e {
            guard check(f, &newest) else { return nil }
        }
        return newest
    }

    nonisolated private static func allocatedSize(_ url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isRegularFile == true { return UInt64(v.totalFileAllocatedSize ?? 0) }
        var total: UInt64 = 0
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        else { return 0 }
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true {
                total += UInt64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    @discardableResult
    nonisolated private static func run(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
