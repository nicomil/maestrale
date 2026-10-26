# Specifiche funzionali (studio di CleanMyMac 5.7.2)

Queste specifiche descrivono **cosa** fa CleanMyMac 5, modulo per modulo, così da poter scrivere da zero un'app personale equivalente. Non contengono codice, testi o asset di MacPaw.

## Fonti e metodo
- **Analisi statica** del bundle `/Applications/CleanMyMac_5.app` (v5.7.2, arm64 + x86_64): nomi delle classi Objective-C (`nm`), simboli Swift demangled (`swift-demangle`), stringhe (`strings`). Output grezzi in `re-notes/` (non versionato).
- **Strumento**: rea 6.8.0 (`rea-agents`), con Ghidra 12.1.4 come motore per il pseudocodice, usato solo dove la logica non si deduce dai nomi.
- **Analisi dinamica** (da fare): `fs_usage` durante una sola scansione, per confermare i percorsi letti. Vedi `dynamic-capture.md`.

## Cosa NON si estrae
- `Contents/Resources/info.cmmkb` (circa 290 KB, cifrato): è la "knowledge base" che alimenta tutti i tipi `*KnowledgeBase` (cache, log, lingue, launch agent, login item, privacy, uninstaller, updater). Non viene decifrato. Le nostre regole si scrivono da zero partendo dalla conoscenza pubblica di macOS e dall'osservazione dinamica.
- Database malware Moonlock (`MalwareDatabaseService`, `/engine/v3/database`) e firme YARA: proprietari. Si usano fonti aperte.
- Licenza, attivazione, telemetria (`ActivationService`, `AnalyticsService`, `CleanMyMacNFRService`).

## Architettura osservata (utile come riferimento)
- **Scansione**: `ScanningCore` gestisce una coda di task con dipendenze, priorità, timeout e progressi composti (`ProcessingQueue`, `DependentTask`, `CompoundProgress`, `TimeoutProblem`). Ogni modulo fornisce una `*ScanTaskFactory`.
- **Pulizia**: `CleaningCore` ha tre strategie di rimozione: `MoveToTrashFileRemover` (Cestino), `FileRemover` (cancellazione diretta) e `PrivilegedFileRemover` (via helper root). C'è anche un `DebugFileRemover` (dry-run).
- **Helper privilegiato**: `com.macpaw.CleanMyMac5.Agent` (LaunchService) più `PrivilegedOperationsPerformerService`, collegati via XPC (`IPCProtocol`).
- **Modelli**: ogni risultato è un nodo di un albero (`CleanableNodeType`, `CleanupAwareNode`), con figli ordinati e dimensione aggregata.

## Indice
| File | Modulo |
|---|---|
| `system-junk.md` | Pulizia sistema (cache, log, lingue, Xcode, binari universali…) |
| `misc-junk.md` | Cestini, allegati Mail, immagini disco inutilizzate, download |
| `uninstaller.md` | Disinstallazione app, avanzi, plugin audio, Steam/Blizzard/JetBrains |
| `updater.md` | Aggiornamenti app (Sparkle, App Store) e di sistema |
| `space-lens.md` | Mappa del disco, file grandi/vecchi, duplicati, foto simili |
| `privacy.md` | Browser, elementi recenti, rete Wi‑Fi, permessi app |
| `performance.md` | Login item, launch agent, manutenzione |
| `malware.md` | Tipi di regole e categorie di rilevamento |
| `helper.md` | Operazioni privilegiate |
| `protection-upgrade.md` | Piano M7: persistenza completa, processi e risorse, YARA, postura, quarantena |
| `dynamic-capture.md` | Procedura di cattura dinamica |
