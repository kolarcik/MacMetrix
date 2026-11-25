import SwiftUI

/// "Úklid disku" wizard: intro → scan → review & select → clean → summary.
struct CleanupView: View {
    @EnvironmentObject var store: MonitorStore
    @StateObject private var model = DiskCleanupModel()
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.phase {
                case .intro: intro
                case .scanning: progress("Prohledávám…")
                case .review: review
                case .cleaning: progress(model.moveToTrash ? "Přesouvám do Koše…" : "Mažu…")
                case .done: summary
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, minHeight: 560)
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(model.moveToTrash ? "Přesunout do Koše" : "Trvale smazat", role: .destructive) { model.clean() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text(model.moveToTrash
                 ? "Místo se uvolní až po vysypání Koše."
                 : "Smazané soubory nepůjde obnovit.")
        }
    }

    private var confirmTitle: String {
        "Uklidit \(Fmt.bytes(model.selectedSize))? Vybrané kategorie: \(model.results.filter(\.selected).count)"
    }

    private var freeSpace: UInt64 { store.current.diskTotal > store.current.diskUsed ? store.current.diskTotal - store.current.diskUsed : 0 }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "internaldrive").font(.system(size: 28)).foregroundStyle(Metric.disk.color)
            VStack(alignment: .leading, spacing: 2) {
                Text("Úklid disku").font(.title2.weight(.semibold))
                Text("Volno \(Fmt.gb(freeSpace)) z \(Fmt.gb(store.current.diskTotal))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            StepIndicator(phase: model.phase)
        }
        .padding(16)
    }

    // MARK: Steps

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Průvodce najde soubory, které se dají bezpečně smazat – mezivýsledky buildů Xcode a .NET, cache balíčkovacích nástrojů, staré dočasné soubory a logy. Před smazáním uvidíš, co a kolik místa se uvolní, a vybereš si kategorie.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Složka s projekty").font(.headline)
                        Text(model.projectsRoot?.path ?? "Nevybráno – build výstupy projektů se nebudou hledat")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Změnit…") { model.chooseProjectsRoot() }
                }
                .padding(4)
            }
            Text("V ní se hledají složky bin/obj vedle .csproj/.fsproj a .build vedle Package.swift.")
                .font(.caption).foregroundStyle(.secondary)

            Spacer()
            HStack {
                Spacer()
                Button("Prohledat") { model.scan() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(20)
    }

    private func progress(_ title: String) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: model.progress)
                .frame(width: 320)
            Text(title).font(.headline)
            Text(model.status).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var review: some View {
        VStack(spacing: 0) {
            List {
                ForEach($model.results) { $r in
                    CleanupRow(result: $r) { model.reveal(r) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if model.isXcodeRunning {
                    Label("Xcode běží – smazání DerivedData během buildu ho může přerušit.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Toggle("Přesunout do Koše místo trvalého smazání", isOn: $model.moveToTrash)
                    Spacer()
                    Text("Vybráno: \(Fmt.bytes(model.selectedSize))").font(.headline).monospacedDigit()
                }
                HStack {
                    Button("Znovu prohledat") { model.scan() }
                    Spacer()
                    Button("Uklidit…") { confirming = true }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .disabled(model.selectedSize == 0)
                }
            }
            .padding(16)
        }
    }

    private var summary: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(.green)
            Text(model.moveToTrash ? "Přesunuto do Koše \(Fmt.bytes(model.freed))" : "Uvolněno \(Fmt.bytes(model.freed))")
                .font(.title2.weight(.semibold))
            if model.failures > 0 {
                Text("\(model.failures) položek se nepodařilo odstranit (používané nebo bez oprávnění).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Znovu prohledat") { model.scan() }
                Button("Hotovo") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
    }
}

private struct CleanupRow: View {
    @Binding var result: DiskCleanupModel.Result
    var reveal: () -> Void

    var body: some View {
        let empty = result.size == 0
        HStack(spacing: 10) {
            Toggle("", isOn: $result.selected).labelsHidden().disabled(empty)
            Image(systemName: result.category.symbol)
                .frame(width: 22)
                .foregroundStyle(empty ? Color.secondary : Metric.disk.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.category.title).font(.body.weight(.medium))
                Text(result.category.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if empty {
                Text("nic k úklidu").font(.callout).foregroundStyle(.tertiary)
            } else {
                Text(Fmt.bytes(result.size)).font(.body.weight(.semibold)).monospacedDigit()
                Button(action: reveal) { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Zobrazit ve Finderu")
            }
        }
        .padding(.vertical, 3)
        .opacity(empty ? 0.6 : 1)
    }
}

private struct StepIndicator: View {
    var phase: DiskCleanupModel.Phase
    private let steps = ["Start", "Hledání", "Výběr", "Úklid"]

    private var current: Int {
        switch phase {
        case .intro: 0
        case .scanning: 1
        case .review: 2
        case .cleaning, .done: 3
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 4) {
                    Circle().fill(i <= current ? Metric.disk.color : Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
                    Text(s).font(.caption).foregroundStyle(i == current ? .primary : .secondary)
                }
            }
        }
    }
}
