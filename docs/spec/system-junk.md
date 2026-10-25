# Pulizia sistema (System Junk)

Framework studiati: `SystemJunkScanning`, `JunkCleanupModule`, `CleaningCore`.
Legenda della colonna **Fonte**: `B` = percorso o comando visto nel binario; `T` = solo il tipo/categoria è nel binario, il percorso viene dalla documentazione pubblica di macOS; `D` = da confermare con la cattura dinamica.
Legenda **Rischio**: basso = si rigenera da solo; medio = si perde uno stato (es. sessione); alto = possibile perdita di dati.

## Categorie (una per task di scansione nel binario)

| Categoria | Task CMM | Percorsi / come trovarli | Condizioni | Rischio | Helper | Fonte |
|---|---|---|---|---|---|---|
| Cache utente | `CMUserCachesScanTask` | `~/Library/Caches/*` | Escludere le cache di app in esecuzione e quelle note come critiche (es. `com.apple.Safari/Webpage Previews` si può, `CloudKit` no). Raggruppare per app tramite bundle ID. | basso | no | T |
| Cache delle app sandbox | `CMSandboxContainersCachesScanTask` | `~/Library/Containers/*/Data/Library/Caches` | Il bundle ID del container indica l'app. | basso | no | B (`Data/Library/Caches`) |
| Cache di sistema | `CMSystemCachesScanTask` | `/Library/Caches/*` | Escludere tutto ciò che è di Apple e protetto da SIP. | medio | sì | T |
| Cache Darwin per utente | `CMDarwinUserCachesScanTask` | `$(getconf DARWIN_USER_CACHE_DIR)` (`/private/var/folders/xx/…/C`) | Solo sottocartelle di app non in esecuzione. | medio | no | T |
| Cache con percorso fisso | `CMHardcodedPathCacheScanTask` | Elenco di app note: Adobe Media Cache (`~/Library/Application Support/Adobe/Common/Media Cache Files`), Spotify (`…/Spotify/PersistentCache/Storage`), Telegram, WeChat, QQMusic, Tencent Video, Youku, Libreria Foto (cache) | Solo se l'app esiste. | basso | no | B |
| Cache Spotify | `CMSpotifyCacheScanTask` | `~/Library/Application Support/Spotify/PersistentCache/Storage` (legge anche `…/Spotify/prefs` per la posizione personalizzata) | | basso | no | B |
| Cache Dropbox | `CMDropboxCacheScanTask` | `~/Dropbox/.dropbox.cache` (o percorso letto da `~/.dropbox/info.json`) | | basso | no | T |
| Cache app Electron | `CMElectronAppsCacheScanTask` | App con `Contents/Frameworks/Electron Framework.framework` → `~/Library/Application Support/<App>/{Cache,Code Cache,GPUCache,Service Worker/CacheStorage}` | Rilevamento dal framework Electron dentro il bundle. | basso | no | B (percorso del framework) |
| Cache Gradle | `CMGradleCacheScanTask` | `~/.gradle/caches` | | basso | no | T |
| Cache download App Store | `CMAppStoreDownloadsCacheScanTask` | cartella download di `com.apple.appstore` nella cache Darwin | Usa un manifest (`CMAppStoreDownloadsManifest`) per sapere cosa è completato. | basso | sì | T, D |
| Cache CoreSymbolication | `CMCoreSymbolicationdCacheScanTask` | `/System/Library/Caches/com.apple.coresymbolicationd` | | basso | sì | T |
| Log utente | `CMUserLogsScanTask` | `~/Library/Logs/*` | | basso | no | T |
| Log di sistema | `CMSystemLogsScanTask` | `/Library/Logs/*`, `/private/var/log/*` (file ruotati `.gz`, `.bz2`, `*.asl`) | Mai i log attivi in scrittura. Esistono anche "diagnostic logs" (`CMDiagnosticLogsProvider`) e "Apple logs" (`CMAppleLogsProvider`): `/Library/Logs/DiagnosticReports`, `~/Library/Logs/DiagnosticReports`. | basso | sì | T |
| Lingue delle app | `CMApplicationLanguagesScanTask` | `<App>.app/Contents/Resources/*.lproj` non usate | Tenere le lingue preferite dell'utente (`Locale.preferredLanguages`), `Base.lproj`, `en.lproj`. **Rompe la firma** delle app non Apple: saltare app firmate/notarizzate e app di sistema. | alto | sì per /Applications di root | B, T |
| Binari universali | `CMUniversalBinariesScanTask` | Eseguibili Mach-O fat in `/Applications` | Rimuovere l'architettura non usata (`lipo -thin`). **Rompe la firma**, CMM tiene una lista di eccezioni (`bundleIdentifiersForArm64`/`ForX86_64`). Consiglio: disattivata di default. | alto | sì | B |
| Preferenze rotte | `CMBrokenPreferencesScanTask` | `~/Library/Preferences/*.plist` non leggibili come plist | Verifica con `PropertyListSerialization`. | basso | no | B (`CFPropertyListCreateWithData`) |
| Login item rotti | `CMBrokenLoginItemsScanTask` | Login item che puntano ad app inesistenti | | basso | no | T |
| Launch agent rotti | `CMBrokenLaunchdAgentsItemsScanTask` | `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons` con `Program`/`ProgramArguments[0]` inesistente | | medio | sì per /Library | T |
| Startup item rotti | `CMBrokenStartupItemsScanTask` | `/Library/StartupItems` (legacy) | | basso | sì | T |
| Versioni dei documenti | `CMDocumentVersionsScanTask` | API `NSFileVersion.otherVersionsOfItem(at:)` per documento | Regola di selezione `CMDocumentVersionsSelectionRule`: tenere l'ultima versione. | medio | no | B |
| Utenti eliminati | `CMDeletedUsersScanTask` | `/Users/Deleted Users/*.dmg` | | alto | sì | T |
| Backup iOS | `CMMobileBackupsTask` | `~/Library/Application Support/MobileSync/Backup/*` | Mostrare dispositivo e data (letti da `Info.plist`); preselezionare solo i backup vecchi o rotti, tenere l'ultimo per dispositivo. | alto | no (serve FDA) | B (`backupWithURL:size:autoselected:latest:date:`) |
| Storico migrazione | (dentro le cache di sistema) | `/Library/SystemMigration/History` | | basso | sì | B |
| Xcode DerivedData | `CMXcodeDerivedDataScanTask` | `~/Library/Developer/Xcode/DerivedData/*` | | basso | no | T |
| Xcode Archives | `CMXcodeArchivesScanTask` | `~/Library/Developer/Xcode/Archives/*` | Non preselezionare (servono per i simboli). | alto | no | T |
| Xcode Device Support | `CMXcodeDeviceSupportJunkScanTask` | `~/Library/Developer/Xcode/{iOS,watchOS,tvOS} DeviceSupport/*` | Preselezionare le versioni vecchie. | basso | no | T |
| Xcode Device Logs | `CMXcodeDeviceLogsScanTask` | `~/Library/Developer/Xcode/iOS Device Logs` | | basso | no | T |
| Xcode Module Cache | `CMXcodeModuleCachesScanTask` | `~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex`, `$(getconf DARWIN_USER_CACHE_DIR)/clang/ModuleCache` | | basso | no | T |
| Xcode documentazione | `CMXcodeModuleDocumentationCachesScanTask` | `~/Library/Developer/Xcode/DocumentationCache` | | basso | no | T |
| Simulatori | `CMXcodeSimulatorsScanTask` | `xcrun simctl list -j devices` → dispositivi non disponibili | Rimozione con `xcrun simctl delete unavailable`. | medio | no | B (`simctl`) |
| Cache CoreSimulator | `CMXcodeCoreSimulatorCachesTask` | `~/Library/Developer/CoreSimulator/Caches` | | basso | no | T |
| Runtime scaricati | `CMXcodeDownloadedRuntimesScanTask` | `xcrun simctl runtime list -j` | Rimozione con `simctl runtime delete`. | medio | no | B |

## Comportamento osservato
- **Logica della scansione cache** (pseudocodice Ghidra di `-[CMCacheScanTask scan]`, evidence `ev_4bb9c5ce…`): prende il contenuto della cartella cache (`contentOfCachesDirectoryURL`), scarta con un predicato OR i file `.DS_Store` e gli elementi della lista di esclusione della knowledge base (`CMFileIgnorePredicate initWithKnowledgeBase:`), poi calcola la dimensione di ogni sottocartella rimasta. È quindi un approccio "tutto tranne le esclusioni", non una lista di cose ammesse. La nostra lista di esclusioni va scritta da zero.
- Le cache sono raggruppate per applicazione (`CMCacheGroupModel`), con nome e icona ricavati dal bundle ID (`applicationNameForBundleIdentifier:`).
- Ogni elemento ha un flag `autoSelected`: CMM preseleziona solo ciò che considera sicuro.
- I comandi esterni usati sono: `xcode-select -p`, `xcrun`, `simctl`, `defaults`, `/bin/sh`.

## Decisioni per la nostra app
- Le categorie ad alto rischio (lingue, binari universali, archivi Xcode, backup iOS, utenti eliminati) sono visibili ma **mai preselezionate**.
- Per tutto si usa il Cestino come default, tranne le cache di sistema root (rimosse dall'helper con log).
- Le regole stanno in `Rules/system-junk.json` (nostre), nel formato `{id, category, paths[], excludes[], conditions, risk, needsHelper, autoSelect}`.
