# Specifiche funzionali

Queste specifiche descrivono **cosa** fa ogni modulo di Maestrale: quali cartelle e quali tipi di file considera, cosa preseleziona, cosa non tocca mai e con quali permessi. Sono il riferimento con cui il codice è stato scritto e con cui va confrontato quando cambia.

Le regole si basano sulla conoscenza pubblica di macOS: posizioni standard di cache e log, launchd e Launch Services, container delle app, database dei browser, TCC, XProtect e Gatekeeper.

## Struttura comune
- **Scansione**: ogni modulo produce categorie di voci con dimensione, rischio e preselezione; le categorie a rischio alto non sono mai preselezionate.
- **Pulizia**: tre modalità, Cestino (predefinita), eliminazione diretta e prova. I file di sistema passano dall'helper privilegiato (`helper.md`).
- **Modelli**: ogni risultato è un nodo di un albero con figli ordinati e dimensione aggregata.

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
