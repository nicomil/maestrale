# Storie pronte per lo sviluppo (Scrum Master)

Ogni storia elenca i file da toccare, i compiti e i test che la chiudono. L'ordine è quello di esecuzione.

## S1: svuotare davvero il Cestino
File: `Core/Rules.swift`, `Core/SafeRemover.swift`, `Modules/TrashModule.swift`, `App/AppModel.swift`, `App/ModuleView.swift`.
1. `RuleEngine.includeEmptyItems`; `TrashModule` lo attiva.
2. `SafeRemover.unlocksItems`; sblocco ricorsivo e secondo tentativo in `.delete`.
3. `AppModel.effectiveMode(moduleID:chosen:)`; `clean` costruisce `SafeRemover(…, mode: effective, unlocksItems: id == "trash")`.
4. `ModuleView`: interruttore "Solo prova", pulsante "Svuota", conferma "L'eliminazione è definitiva", banner senza "Apri Cestino".
Test: `RuleEngineTests.emptyItemsAreKeptWhenAsked`, `SafeRemoverTests.deleteUnlocksLockedFilesWhenAsked` e `deleteLeavesLockedFilesAloneByDefault`, `AppModelTests.trashModuleAlwaysDeletes`.

## S2: disinstallare le app di root
File: `Modules/Apps/InstalledApps.swift`, `App/AppsModels.swift`, `App/UninstallerView.swift`.
1. `isWritable` con `isWritableFile`.
2. Bundle preselezionato anche con `needsHelper`.
3. Secondo tentativo tramite helper per i fallimenti di permesso sotto `systemRoots`.
4. Conferma con avviso password; comandi "Tutti / Nessuno".
Test: `AppModelTests.bundleIsPreselectedEvenWhenItNeedsThePassword` (bundle reso non scrivibile con `chmod 555`), `AppModelTests.permissionFailuresAreRetriedAsAdmin` (con un `removeAsAdmin` finto).

## S3: aggiornamenti coerenti
File: `Modules/Apps/Updates.swift`, `App/AppsModels.swift`, `App/UpdatesView.swift`.
1. `AppUpdate.availableBuild`, `isStillPending(for:)`.
2. iTunes: `minimumOsVersion`, `trackId`, link `macappstore://`.
3. Homebrew: scarto delle voci non più nuove.
4. `UpdatesModel.refresh()` e i tre punti di chiamata; ora dell'ultimo controllo nell'intestazione.
Test: `AppsTests.updateStaysOnlyWhileInstalledVersionIsOlder`, `AppsTests.storeLookupSkipsUnsupportedSystems`, `AppsTests.storeAndBrewParsing` aggiornato.

## S4: seleziona tutto / deseleziona tutto
File: `App/AppModel.swift`, `App/ModuleView.swift`, `App/SpaceLensView.swift`, `App/UninstallerView.swift`, `App/SystemViews.swift`, `App/SystemModels.swift`.
1. `AppModel.selectAll(in:matching:)`, `deselectAll(in:)`.
2. `SpaceLensModel.selectAll()`, `PrivacyModel.selectAll()`, `UninstallerModel.selectAllFiles()`.
3. Pulsanti nelle quattro viste, disattivati quando inutili.
Test: `AppModelTests.selectAllRespectsFilterAndKeptCopies`, `AppModelTests.spaceLensSelectAllSkipsAggregates`.

## S5: avanzi più sicuri
File: `Modules/Apps/OrphanLeftoversModule.swift`, `App/ModuleView.swift` (descrizione).
1. Dipendenze iniettabili (`commands`, `launchItems`).
2. `parseLaunchctlLabels`, label dei plist, unione in `known`.
3. `classify(modified:now:)` e nota per elemento.
Test: `AppsTests.launchctlLabelsAreParsed`, `AppsTests.recentlyModifiedLeftoversAreHighRisk`, `AppsTests.launchdLabelsProtectLeftovers` (modulo su una home finta).

## S6: Protezione leggibile
File: `App/ProtectionView.swift`.
1. `ProtectionModel.Filter`, `filteredFindings`, `categoryCounts`, `worstSeverity(in:)`.
2. Barra di riepilogo, colonna categorie, righe compatte espandibili, menu secondario.
3. `showInfo` resta come proprietà derivata dal filtro, per compatibilità.
Test: `AppModelTests.protectionFilterNarrowsBySeverityCategoryAndText` (con `Finding` costruiti a mano).

## Definizione di fatto
- `swift test` del pacchetto e `xcodebuild test` dell'app verdi.
- Build Debug dell'app riuscita.
- README aggiornato (sezione Sicurezza e tabella dello stato).
- `qa.md` compilato con gli esiti.
