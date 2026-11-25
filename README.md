# MacMetrix

Menu bar aplikace pro macOS 14+ sledující zatížení **CPU, GPU, RAM, disku a sítě** – určená pro Mac mini build servery, na které se chodí přes VNC.

## Co umí

- **Samostatné ukazatele ve stavové liště** – CPU, GPU, RAM, Disk a Síť mají každý vlastní položku s pevnou šířkou; které se zobrazí, se vybírá v Nastavení. Vzhled: *Dvouřádkově*, *Ikona*, *Text* nebo *Sloupec*. Když není vybrané nic, zobrazí se jen ikona aplikace. Položky jde přeskládat přes ⌘ + tažení.
- **Miniatura grafu** za každým ukazatelem (volitelně v Nastavení) – posledních 40 měření.
- **Okno každé metriky** po kliknutí na její ikonu: ukazatele, historie, detaily a nejaktivnější procesy (CPU i s teplotou čipu, Disk s teplotou SSD).
- **Úklid disku** – průvodce (z okna Disku) najde a smaže DerivedData, podporu zařízení, nedostupné simulátory, cache SPM/CocoaPods/NuGet/npm/Homebrew/Gradle, bin/obj a .build v projektech, staré dočasné soubory a logy. Nejdřív ukáže velikosti a nechá vybrat kategorie; mazat jde trvale nebo do Koše.
- **Dashboard okno** – velké gauge, grafy (5 min / 1 hod) a vytížení jednotlivých jader CPU.
- **Widgety na plochu** (malý / střední / velký) s historií za poslední hodinu.
- **Spouštění po přihlášení** – zapne se samo při prvním spuštění (`SMAppService`), lze vypnout v ⚙︎.

### Co se měří

| Metrika | Zdroj | Poznámka |
|---|---|---|
| CPU | `host_processor_info`, IOHID teplotní senzory | celkem, user/system, po jádrech, load average; teplota (průměr / max `PMU tdie*`, jen Apple Silicon) |
| GPU | IOKit `IOAccelerator → PerformanceStatistics` | „Device Utilization %“ + využitá paměť GPU |
| RAM | `host_statistics64` | „Použitá paměť“ jako v Monitoru aktivity (app + wired + komprimovaná), swap |
| Disk | `/` resource values, IOKit `IOBlockStorageDriver` | obsazenost systémového svazku (gauge) + čtení/zápis B/s (graf) |
| Síť | `sysctl IFMIB_IFDATA` (64bit čítače) | zvlášť **IN ↓ / OUT ↑**; počítají se jen rozhraní `en*`, takže loopback, VPN a bridge VM (např. tart) se nezapočítají dvakrát. Když systém na `en*` příchozí bajty nehlásí (stává se s VPN / síťovými rozšířeními), bere se IN z VPN tunelů a v legendě je „(VPN)“. |

Gauge sítě je vztažený k 1 Gbit/s (125 MB/s).

## Widgety a jejich obnovování

Aplikace v nastaveném intervalu (výchozí 10 s, v Nastavení 5 s – 1 min) zapíše data do sdíleného App Group kontejneru a požádá WidgetKit o obnovení. **macOS ale obnovování widgetů omezuje**, takže widget nemusí být aktuální na sekundu – ukazuje čas posledního měření. Pro živá data slouží popover a dashboard. Když aplikace neběží, widget si změří hodnoty sám (bez historie).

Přidání: pravý klik na plochu → *Upravit widgety* → MacMetrix.

## Sestavení

Potřeba: Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open MacMetrix.xcodeproj
```

Podepisuje se certifikátem **Developer ID Application** týmu `3ZN9TSG9S7` (nastaveno v `project.yml` – `DEVELOPMENT_TEAM`). App Group má tvar `<TEAM>.tech.synot.MacMetrix`, takže nepotřebuje provisioning profil.

Release balíček:

```bash
./scripts/release.sh
```

S notarizací (doporučeno pro distribuci na další stroje; profil se vytvoří jednou přes `xcrun notarytool store-credentials`):

```bash
NOTARY_PROFILE=synot ./scripts/release.sh
```

## Instalace na Mac mini

1. Zkopírovat `dist/MacMetrix.zip` a `dist/install.sh` na stroj (např. `scp`).
2. Spustit **pod uživatelem, který je přihlášený v GUI / přes VNC**: `./install.sh MacMetrix.zip`
3. Při prvním spuštění se aplikace zaregistruje jako položka po přihlášení – macOS zobrazí notifikaci; ověřit v *Nastavení systému → Obecné → Položky při přihlášení*.
4. Aby aplikace běžela hned po restartu serveru, musí mít Mac mini zapnuté **automatické přihlášení** (*Nastavení systému → Uživatelé a skupiny → Automaticky přihlásit*) – login item se spouští až po přihlášení uživatele.

## Struktura

```
App/       menu bar aplikace (MenuBarExtra, popover, dashboard, store, login item)
Widget/    WidgetKit extension
Shared/    měření metrik, sdílený stav, společné SwiftUI komponenty (gauge, grafy)
scripts/   release.sh, install.sh, make-icon.swift (generuje ikonu aplikace)
project.yml  definice projektu pro XcodeGen
```
