# Updater

Framework: `UpdaterScanning`, `AppInfoNetworkService`, `MASUpdaterService`.

## Fonti osservate nel binario
| Fonte | Tipo CMM | Come funziona |
|---|---|---|
| App con Sparkle | `SparkleApplicationsDataSource`, `SparkleAppFeedProvider`, `SparkleAppValidator` | L'app contiene `Contents/Frameworks/Sparkle.framework` e la chiave `SUFeedURL` in `Info.plist` (B). Si scarica l'appcast XML e si confronta `sparkle:version` / `sparkle:shortVersionString` con `CFBundleVersion` / `CFBundleShortVersionString`. |
| App dell'App Store | `MASApplicationsDataSource` | App con `Contents/_MASReceipt/receipt`. CMM usa un proprio servizio per ottenere le versioni. |
| Database MacPaw | `AppInfoNetworkService`, `UpdaterKnowledgeBaseType` | Servizio proprietario che fornisce versioni e URL di download per app senza Sparkle (campo `sparkle_feed_url` nelle risposte). **Non replicabile.** |
| macOS | `SystemUpdateScanTask` | Aggiornamenti di sistema disponibili. |

## Sostituti nella nostra app
| Fonte | Implementazione |
|---|---|
| Sparkle | Uguale a CMM: `SUFeedURL` → appcast → confronto versioni con `compare(_:options: .numeric)`. Ignorare gli elementi con `sparkle:minimumSystemVersion` superiore al sistema attuale. |
| App Store | `https://itunes.apple.com/lookup?bundleId=<id>&country=<paese>` → campo `version`. L'aggiornamento si apre in App Store (`macappstore://apps.apple.com/app/id<trackId>`). |
| Homebrew Cask | `brew outdated --cask --greedy --json=v2` se `brew` esiste. |
| macOS | `softwareupdate --list` (lento, da eseguire in background). |

## Azione
- Mostrare versione installata, versione disponibile, note di rilascio (dall'appcast) e fonte.
- "Aggiorna": per Sparkle si apre l'app (è lei che si aggiorna); per Homebrew `brew upgrade --cask <token>`; per App Store si apre la pagina.
- Nessun download e installazione automatici fatti da noi: troppi rischi di firma.
