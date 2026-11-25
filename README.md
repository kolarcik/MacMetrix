# MacMetrix

Menu bar aplikace pro macOS 14+ sledující zatížení **CPU, GPU, RAM, disku a sítě** – určená pro Mac mini build servery, na které se chodí přes VNC.

## Co umí

- **Ikona ve stavové liště** – 5 mini sloupců (CPU · GPU · RAM · Disk · Síť), případně text / jen ikona (nastavení v ⚙︎).
- **Popover** po kliknutí: hodnoty + grafy za posledních 5 minut, load average, uptime.
- **Dashboard okno** – velké gauge, grafy (5 min / 1 hod) a vytížení jednotlivých jader CPU.
- **Widgety na plochu** (malý / střední / velký) s historií za poslední hodinu.
- **Spouštění po přihlášení** – zapne se samo při prvním spuštění (`SMAppService`), lze vypnout v ⚙︎.

### Co se měří

| Metrika | Zdroj | Poznámka |
|---|---|---|
| CPU | `host_processor_info` | celkem, user/system, po jádrech, load average |
| GPU | IOKit `IOAccelerator → PerformanceStatistics` | „Device Utilization %“ + využitá paměť GPU |
| RAM | `host_statistics64` | „Použitá paměť“ jako v Monitoru aktivity (app + wired + komprimovaná), swap |
| Disk | `/` resource values, IOKit `IOBlockStorageDriver` | obsazenost systémového svazku (gauge) + čtení/zápis B/s (graf) |
| Síť | `sysctl NET_RT_IFLIST2` (64bit čítače) | jen rozhraní `en*` – loopback, VPN a bridge VM (např. tart) se nepočítají dvakrát |

Gauge sítě je vztažený k 1 Gbit/s (125 MB/s).

## Widgety a jejich obnovování

Aplikace každou minutu zapíše data do sdíleného App Group kontejneru a požádá WidgetKit o obnovení. **macOS ale obnovování widgetů omezuje**, takže widget nemusí být aktuální na sekundu – ukazuje čas posledního měření. Pro živá data slouží popover a dashboard. Když aplikace neběží, widget si změří hodnoty sám (bez historie).

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
scripts/   release.sh, install.sh
project.yml  definice projektu pro XcodeGen
```
