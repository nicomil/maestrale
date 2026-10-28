# Architettura (Architect)

Il progetto ha tre livelli: `MacCleanerCore` (modelli, regole, rimozione sicura), `MacCleanerModules` (scansioni e operazioni) e l'app SwiftUI (`App/`). Le modifiche seguono la stessa divisione: la logica va nei pacchetti, dove è testabile con `swift test`; le viste cambiano solo come mostrano e invocano quella logica.

## Core

### `RuleEngine`
- Nuovo parametro `includeEmptyItems` (predefinito `false`): quando è `true`, gli elementi di dimensione zero restano nei risultati. Serve solo al modulo Cestini. Il test esistente `emptyFoldersAreNotReported` resta valido per il comportamento predefinito.

### `SafeRemover`
- Nuovo parametro `unlocksItems` (predefinito `false`). Con `.delete`, se `removeItem` fallisce e il flag è attivo, l'elemento e il suo contenuto vengono sbloccati (`chflags` senza `UF_IMMUTABLE`) e la rimozione viene ripetuta una volta. I controlli di `validate` non cambiano: lo sblocco avviene solo dentro le cartelle consentite, dopo il controllo di SIP, e solo in eliminazione definitiva. Il Cestino è l'unico modulo che lo attiva.

## Modules

### `TrashModule`
- Espone `RuleEngine(home:includeEmptyItems: true)`.
- Nuova proprietà statica `requiresPermanentDeletion = true`, letta dall'app per imporre la modalità.

### `InstalledApp`
- `isWritable` diventa "cartella madre scrivibile e bundle scrivibile" (`isDeletableFile && isWritableFile`). È la condizione reale per `rename(2)` di una cartella verso un'altra cartella madre.

### `UpdateChecker` e `AppUpdate`
- `AppUpdate` acquista `availableBuild: String?` (il `sparkle:version` dell'appcast) e il metodo `isStillPending(for installed: InstalledApp) -> Bool`, che ripete il confronto fatto dal controllo per ogni fonte.
- La ricerca iTunes legge anche `minimumOsVersion` e `trackId`; le voci che richiedono un macOS più recente sono scartate e la pagina è `macappstore://apps.apple.com/app/id<trackId>`.
- Homebrew: una voce di `brew outdated --greedy` è tenuta solo se la versione del cask è più nuova di quella dell'app installata (o se la versione del cask non è confrontabile, come `latest`).

### `OrphanLeftoversModule`
- Nuove dipendenze iniettabili: `commands: any CommandRunner` (per `launchctl list`) e `launchItems: (() -> [LaunchItem])`.
- Insieme `known` esteso con le label dei plist di launchd e delle righe di `launchctl list` (funzione pura `parseLaunchctlLabels`).
- Per ogni elemento: data di ultima modifica, `classify(modified:now:)` restituisce rischio e nota ("modificato N giorni fa, forse ancora in uso" entro 30 giorni; altrimenti "ultima modifica N mesi fa").

## App

### `AppModel`
- `static func effectiveMode(moduleID:chosen:)`: per il modulo Cestini `.trash` diventa `.delete`; per gli altri resta la scelta dell'utente. Usata da `clean`, dal piè di pagina e dal banner.
- `selectAll(in:matching:)` e `deselectAll(in:)`: agiscono sugli elementi visibili con il filtro, saltando `category.keep`.
- `removeAsAdmin` invariata.

### `UninstallerModel`
- `select`: il bundle è preselezionato anche se `needsHelper`.
- `run`: dopo la rimozione utente, gli esiti falliti per permessi su percorsi dentro `AdminRunner.systemRoots` vengono ritentati con `removeAsAdmin` (una sola richiesta di password).
- `selectAllFiles()` / `deselectAllFiles()`.

### `UpdatesModel`
- `refresh()`: rilegge ogni app dell'elenco con `AppInventory.read(computeSize: false)` fuori dal main actor e tiene solo le voci ancora pendenti. Chiamata da `UpdatesView.task`, da `NSApplication.didBecomeActiveNotification` e alla fine di `update(_:)`.

### `SpaceLensModel`, `PrivacyModel`
- `selectAll()` / `deselectAll()`.

### Viste
- `ModuleView`: intestazione con "Seleziona tutto / Deseleziona tutto"; per il Cestino un interruttore "Solo prova" al posto del selettore di modalità, pulsante "Svuota", conferma esplicita; il banner non offre "Apri Cestino" quando la modalità effettiva è `.delete`.
- `SpaceLensView`, `UninstallerView`, `PrivacyView`: stessi comandi di selezione.
- `ProtectionView`: nuovo `ProtectionModel.Filter` (gravità, solo nuovi, ricerca, categoria) con `filteredFindings` e `categoryCounts`; layout a due colonne (`HSplitView`): categorie a sinistra, risultati a destra; righe compatte espandibili (`FindingRow` riscritta). `visibleFindings`, `newFindings`, `newDangers` e `groups` restano, perché usati da Smart Care, dal badge e dallo scheduler.

## Sicurezza (invarianti che non cambiano)
- `SafeRemover.validate` e `AllowedRoots` restano la barriera: lo sblocco dei file è un passo in più solo dopo che un elemento è stato accettato.
- Nessuna nuova `AdminOperation`: la disinstallazione delle app di root usa `moveToTrash`/`remove` già esistenti, e `/Applications` è già in `SystemRoots`.
- Gli avanzi restano mai preselezionati; il modulo diventa più restrittivo, non meno.
