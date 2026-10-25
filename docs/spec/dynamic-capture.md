# Cattura dinamica dei percorsi letti da CleanMyMac

Serve a confermare i percorsi marcati `T` o `D` nelle specifiche. Si osserva **solo la scansione**: non premere mai "Pulisci" durante la cattura.

## Procedura
1. Chiudere CleanMyMac.
2. In un Terminale separato (serve la password di amministratore):
   ```bash
   cd /Users/nico/wa/maccleaner
   ./scripts/capture-cmm.sh
   ```
   Lo script avvia `fs_usage` filtrato sui processi di CleanMyMac e del suo agent, e scrive in `re-notes/dynamic/fs_usage-<data>.log`.
3. Aprire CleanMyMac e lanciare una scansione alla volta: Pulizia, Protezione, Prestazioni, Applicazioni, Ingombro (Space Lens), Privacy.
4. Tornare al Terminale e premere `Ctrl+C`.
5. Riassunto dei percorsi:
   ```bash
   ./scripts/summarize-capture.sh re-notes/dynamic/fs_usage-<data>.log
   ```
   Produce `re-notes/dynamic/paths-<data>.txt` con le cartelle radice lette, ordinate per frequenza.

## Risultati della cattura del 25/10/2026
Scansione globale (Smart Care) di circa 3 minuti, 1 GB di log, 43.131 cartelle diverse.

**Scritture**: 729 chiamate (unlink, rmdir, rename), tutte su file di CleanMyMac stesso: un pacchetto `Office16_autoupdate_updater.pkg` scompattato in una cartella temporanea per l'analisi malware e poi rimosso, più file nel suo Group Container e nella sua cache. Nessun file dell'utente è stato modificato.

**Confermato (fonte `D`)**
| Area | Cosa legge | Modulo |
|---|---|---|
| `~/Library/Caches`, `~/Library/Containers/*/Data/Library/Caches` | tutte le sottocartelle | Pulizia sistema |
| `~/Library/Application Support/*` | `Cache`, `Code Cache`, `GPUCache`, `DawnWebGPUCache`, `DawnGraphiteCache`, `Service Worker/CacheStorage`, `Crashpad/{pending,completed}` | Pulizia sistema (cache Electron/Chromium) |
| `~/Library/Containers/*/Data/Library/Logs`, `~/Library/Logs` (anche `DiagnosticReports/Retired`) | log | Pulizia sistema |
| `/Library/Logs/DiagnosticReports`, `/Library/Logs/CrashReporter/CoreCapture/WiFi`, `/private/var/log/*.bz2` | log di sistema e ruotati | Pulizia sistema (helper) |
| `/Library/Caches/*/org.sparkle-project.Sparkle/PersistentDownloads`, `/Library/Caches/*.ShipIt` | aggiornamenti scaricati e rimasti | Pulizia sistema (helper) |
| `~/Library/Mail/V10/<account>/…` | allegati | Allegati Mail |
| `/Applications/*.app/Contents/{Resources,Frameworks,PlugIns}` | lingue e architetture | Lingue / binari universali |
| `~/Downloads/**` (tutto, ricorsivo) | dimensioni e date | File grandi e vecchi |
| `/System/Applications`, `/System/iOSSupport`, `/usr/local/**`, `/private/var/db/DetachedSignatures`, `/private/var/db/SystemPolicyConfiguration/XProtect.app` | firme e inventario | Malware |
| `~/Library/Group Containers/*`, `~/Library/Application Scripts/*` | elenco dei bundle ID | Uninstaller (avanzi) |

Le regole aggiunte di conseguenza sono in `system-junk.json` (`browser-profile-caches`, `sandbox-logs`, nuove voci in `electron-caches` e `system-logs`).

## Come usare il risultato
Per ogni cartella radice nuova o diversa da quelle in `system-junk.md` e negli altri file, aggiornare la riga della specifica e cambiare la fonte in `D`.
