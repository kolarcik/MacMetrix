import AppKit
import SwiftUI

/// O aplikaci MacMetrix: značkový panel se symbolem a sloganem, verze, poznámka
/// o soukromí, autor (logo KOLARCIK) a právní dokumenty. Stejné rozložení jako DockPeek a Mindonia.
struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return String(localized: "Verze \(short) (\(build))")
    }

    var body: some View {
        VStack(spacing: 24) {
            BrandPanel()

            Text(version)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Label("Všechna měření probíhají jen na vašem Macu a nikam se neodesílají. MacMetrix nemá žádný server, reklamy ani analytiku.",
                  systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 420, alignment: .leading)

            VStack(spacing: 12) {
                Text("Vytvořil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CreatorLogo()
                    .frame(maxWidth: 260)
                    .accessibilityLabel(Text(verbatim: "KOLARCIK – Simple solutions for complex days"))
                Text(verbatim: "© 2026 Luděk Kolarčík")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                LegalLinks()
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Vzhled ikony aplikace: bílé sloupce na tmavě modrém přechodu, s názvem a sloganem.
private struct BrandPanel: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: AppGlyph.image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 88, height: 88)
                .padding(24)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            Text(verbatim: "MacMetrix")
                .font(.system(size: 40, weight: .bold, design: .rounded))
            Text("Výkon vašich Maců na první pohled.")
                .font(.headline)
                .opacity(0.85)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                // Barvy podkladu ikony aplikace (scripts/make-icon.swift)
                LinearGradient(colors: [Color(red: 0.20, green: 0.23, blue: 0.33),
                                        Color(red: 0.05, green: 0.07, blue: 0.11)],
                               startPoint: .top, endPoint: .bottom)
                // Barvy metrik jako jemná záře
                LinearGradient(colors: Metric.allCases.map(\.color).map { $0.opacity(0.22) },
                               startPoint: .leading, endPoint: .trailing)
                    .blendMode(.screen)
                RadialGradient(colors: [.white.opacity(0.14), .clear], center: .top, startRadius: 0, endRadius: 260)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("MacMetrix. Výkon vašich Maců na první pohled."))
    }
}

/// Logo autora – světlá a tmavá varianta podle vzhledu.
private struct CreatorLogo: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let name = colorScheme == .dark ? "CreatorLogo-dark" : "CreatorLogo"
        if let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Text(verbatim: "KOLARCIK").font(.title3.weight(.semibold))
        }
    }
}

// MARK: - Právní dokumenty

/// Podmínky použití a Zásady ochrany soukromí.
enum LegalDocument: String, Identifiable, CaseIterable {
    case terms, privacy

    var id: String { rawValue }

    static let effectiveDate = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 25).date ?? .now

    var title: String {
        switch self {
        case .terms: String(localized: "Podmínky použití")
        case .privacy: String(localized: "Zásady ochrany soukromí")
        }
    }

    struct Section: Identifiable {
        let title: String
        let text: String
        var id: String { title }
    }

    var intro: String {
        switch self {
        case .terms:
            String(localized: "MacMetrix je bezplatná aplikace, která ve stavové liště, v oknech a ve widgetech ukazuje vytížení CPU, GPU, paměti, disku a sítě. Používáním aplikace souhlasíte s těmito podmínkami.")
        case .privacy:
            String(localized: "MacMetrix je postavený tak, aby jeho autor neměl přístup k ničemu z vašeho Macu. Tyto zásady popisují, s jakými daty aplikace pracuje a kam se dostanou.")
        }
    }

    var sections: [Section] {
        switch self {
        case .terms: [
            Section(title: String(localized: "Aplikace „tak, jak je“"),
                    text: String(localized: "MacMetrix je poskytován zdarma a bez záruky, tak jak je. Autor se snaží, aby fungoval spolehlivě a měřil přesně, ale nezaručuje, že je bez chyb. Odpovědnost autora je omezena v rozsahu, který zákon dovoluje.")),
            Section(title: String(localized: "Úklid disku"),
                    text: String(localized: "Průvodce úklidem disku maže jen kategorie, které sami vyberete a potvrdíte. Trvale smazané soubory nejde obnovit – pokud si nejste jisti, zvolte přesun do Koše. Za smazaná data odpovídá uživatel.")),
            Section(title: String(localized: "Systémové údaje"),
                    text: String(localized: "Teploty čte MacMetrix z teplotních senzorů Apple Silicon přes neveřejné systémové rozhraní. Jejich dostupnost a přesnost se může s verzemi macOS měnit. Seznam procesů vychází ze systémových nástrojů ps a nettop.")),
            Section(title: String(localized: "Spouštění po přihlášení"),
                    text: String(localized: "Při prvním spuštění se MacMetrix zaregistruje jako položka při přihlášení. Vypnout to můžete v Nastavení aplikace nebo v Nastavení systému.")),
            Section(title: String(localized: "Změny podmínek"),
                    text: String(localized: "Podmínky se mohou s novými verzemi aplikace měnit. Aktuální znění je vždy v okně O aplikaci MacMetrix.")),
        ]
        case .privacy: [
            Section(title: String(localized: "Žádný sběr dat"),
                    text: String(localized: "MacMetrix nemá vlastní server. Autor neshromažďuje, nevidí ani nezpracovává žádná vaše data. Aplikace neobsahuje reklamy, analytiku ani sledování a nesdílí žádná data s třetími stranami.")),
            Section(title: String(localized: "Měření"),
                    text: String(localized: "Hodnoty výkonu, názvy procesů a síťová rozhraní se čtou přímo ze systému vašeho Macu a drží se v paměti. Pro widget se ukládá poslední měření a průměry za poslední hodinu do sdílené složky aplikace na tomto Macu; nic se neodesílá.")),
            Section(title: String(localized: "Úklid disku"),
                    text: String(localized: "Průvodce prochází jen známé složky s cache a build výstupy a vámi zvolenou složku s projekty. Výsledky hledání zůstávají v paměti a nikam se neposílají.")),
            Section(title: String(localized: "Nastavení"),
                    text: String(localized: "Zvolené ukazatele, vzhled a intervaly se ukládají jen lokálně v předvolbách aplikace. Odstraněním aplikace a jejích předvoleb zmizí vše, co MacMetrix uložil.")),
        ]
        }
    }
}

struct LegalDocumentView: View {
    let document: LegalDocument
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(document.title).font(.title2.weight(.bold))
                    Text(document.intro).font(.body)
                    ForEach(document.sections) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title).font(.headline)
                            Text(section.text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("Platné od \(LegalDocument.effectiveDate.formatted(.dateTime.day().month(.wide).year()))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Hotovo", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
    }
}

/// Odkazy na právní dokumenty – otevírají se v listu (sheet) nad oknem O aplikaci.
struct LegalLinks: View {
    @State private var shown: LegalDocument?

    var body: some View {
        HStack(spacing: 16) {
            ForEach(LegalDocument.allCases) { document in
                Button(document.title) { shown = document }
                    .buttonStyle(.link)
                    .font(.footnote)
            }
        }
        .sheet(item: $shown) { document in
            LegalDocumentView(document: document) { shown = nil }
        }
    }
}
