# Performance

Framework: `PerformanceScanning`, `PerformanceService`, `PerformanceModule`.

## Elementi di avvio
| Elemento | Tipo CMM | Implementazione |
|---|---|---|
| Login item | `LoginItemsScanTaskFactory`, `LoginItemsKnowledgeBase` | Elenco da Background Task Management: `sfltool dumpbtm` (testo, da analizzare) oppure i plist in `~/Library/Application Support/com.apple.backgroundtaskmanagementagent/`. Disattivazione: tramite Impostazioni (link diretto a `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`) o `osascript` per i login item classici. |
| Background item / launch agent | `BackgroundItemsScanTaskFactory`, `LaunchAgentsKnowledgeBase` | Plist in `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons` (B). Stato con `launchctl print gui/<uid>/<label>`. Disattivazione con `launchctl bootout` + `launchctl disable`; rimozione = sposta il plist nel Cestino (helper per /Library). |

La "knowledge base" di CMM serve a mostrare un nome e una descrizione leggibili per ogni agent noto. Noi ricaviamo il nome dall'app che contiene l'eseguibile, più un piccolo dizionario nostro.

## Attività di manutenzione (`PerformanceTaskIdentifier`)
| Attività | Runner CMM | Comando nella nostra app | Helper |
|---|---|---|---|
| Libera RAM | `FreeUpRAMTaskRunner`, `CMRAMCleaner` | `purge` | sì |
| Libera spazio "eliminabile" | `FreeUpPurgeableSpaceTaskRunner` | Crea e rimuove un file grande temporaneo per forzare il sistema a liberare spazio purgeable; elimina gli snapshot locali di Time Machine con `tmutil thinlocalsnapshots / <bytes> 4` (B: `/usr/bin/tmutil`) | no per tmutil thin |
| Svuota cache DNS | `FlushDNSCacheTaskRunner` | `dscacheutil -flushcache; killall -HUP mDNSResponder` | sì |
| Reindicizza Spotlight | `ReindexSpotlightTaskRunner`, `ReindexSpotlightObserver` | `mdutil -E /` (B: `mdimport` per singoli percorsi) | sì |
| Velocizza Mail | `SpeedUpMailTaskRunner` | Mail chiusa → `sqlite3 ~/Library/Mail/V*/MailData/Envelope\ Index "VACUUM;"` | no (FDA) |
| Ripara permessi del disco | `RepairDiskPermissionsTaskRunner` | `diskutil resetUserPermissions / $(id -u)` | sì |
| Script di manutenzione | (`periodicScripts`) | `periodic daily weekly monthly` (sistemi recenti: non più necessario, opzionale) | sì |

Ogni attività ha una disponibilità (`PerformanceMaintenanceTaskAvailability`): ad esempio "Velocizza Mail" solo se Mail è configurata.

## Monitor (menu bar)
Dati senza privilegi: CPU e memoria con `host_statistics64`, disco con `URLResourceValues.volumeAvailableCapacityForImportantUsage`, batteria con IOKit (`IOPSCopyPowerSourcesInfo`), temperatura non disponibile senza API private (escluso).
