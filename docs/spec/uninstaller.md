# Uninstaller e avanzi

Framework: `UninstallerScanning`, `ApplicationsService`, `ApplicationsTerminator`, `ApplicationsModule`.

## Fonti delle applicazioni
| Tipo | Tipo CMM | Come trovarle |
|---|---|---|
| App normali | `UninstallerApplication` | `/Applications`, `~/Applications`, sottocartelle; escludere `/System/Applications` (B). Spotlight `kMDItemContentType == com.apple.application-bundle` per le app altrove. |
| App iOS su Mac (Apple Silicon) | `MobileUninstallerApplication` | Bundle con `WrappedBundle` / `iTunesMetadata.plist`. |
| Avanzi di app già cancellate | `LeftoverUninstallerApplication`, `LeftoversFetcher` | Bundle ID trovati nelle cartelle di supporto (sotto) che non corrispondono a nessuna app installata. |
| Giochi Steam | `SteamUninstallerApplication` | Librerie lette da `~/Library/Application Support/Steam/steamapps/libraryfolders.vdf` e manifest `appmanifest_*.acf`. |
| Giochi Blizzard | `BlizzardUninstallerApplication` | App Battle.net in `/Applications` con identificazione dedicata. |
| IDE JetBrains | `JetBrainsUninstallerApplication` | App installate da Toolbox (`~/Library/Application Support/JetBrains/Toolbox/apps`). |
| Plugin audio | `UninstallerAudioPlugin` | `/Library/Audio/Plug-Ins/{Components,VST,VST3}`, `~/Library/Audio/Plug-Ins/…`, `/Library/Application Support/Avid/Audio/Plug-Ins` (AAX) (B). |
| Altri plugin | (stessa logica) | `/Library/ColorPickers`, `/Library/PDF Services`, `/Library/Internet Plug-Ins`, `/Library/QuickLook`, `/Library/Spotlight`, `/Library/PreferencePanes`, `/Library/Screen Savers` e le versioni in `~/Library`. |

## Ricerca dei file collegati a un'app
Dato `bundleID`, `appName`, `teamID` e i nomi dei componenti del nome (`_nameComponents`), cercare in `~/Library` e `/Library`:

| Cartella | Criterio |
|---|---|
| `Application Support/` | cartella = nome app o bundle ID |
| `Caches/`, `HTTPStorages/`, `WebKit/` | bundle ID |
| `Preferences/` | `<bundleID>.plist`, `<bundleID>.*.plist`, e `ByHost/<bundleID>.*.plist` |
| `Containers/` | bundle ID, e bundle ID delle estensioni dell'app (`_allBundleIDsAppropriateToContainers`) |
| `Group Containers/` | `<teamID>.*` dichiarati nell'entitlement `application-groups` |
| `Saved Application State/` | `<bundleID>.savedState` (B) |
| `Logs/` | nome app o bundle ID (B) |
| `LaunchAgents/`, `/Library/LaunchDaemons/` | plist il cui `Label` o eseguibile punta all'app (B) |
| `/Library/PrivilegedHelperTools/` | helper dichiarati in `SMPrivilegedExecutables` dell'app (B) |
| `/Library/SystemExtensions` | estensioni di sistema dell'app; vanno disattivate con `systemextensionsctl`, non cancellate (B) |
| `Cookies/` | `<bundleID>.binarycookies` (B) |
| `/private/var/db/receipts` | ricevute `pkgutil --pkgs` con prefisso simile; usare `pkgutil --files` per l'elenco completo dei file installati |
| `Documentation/Applications` | nome app (B) |

Regole: confronto sul bundle ID esatto oppure prefisso con punto (`com.foo.app.` ma non `com.foo.application`). Il solo nome dell'app genera falsi positivi; si usa solo con almeno due componenti o un match esatto. Mai toccare elementi di Apple (`com.apple.*`) né app di sistema.

## Azioni
- **Disinstalla**: chiude l'app (`ApplicationsTerminator`: prima `terminate`, poi `forceTerminate` dopo un timeout), sposta nel Cestino il bundle e i file collegati scelti.
- **Reset**: come la disinstallazione ma lascia il bundle (cancella preferenze, container, cache, stato salvato).
- **Rimuovi solo gli avanzi**: per le app già cancellate.
- Le app installate dall'App Store si possono rimuovere solo se l'utente ne è proprietario; quelle con un proprio uninstaller (es. Adobe) vanno segnalate con un link all'uninstaller ufficiale.
- Le app protette da `ApplicationContainerAccessProbe` (container illeggibile senza permesso) richiedono Full Disk Access.

## Nota sui file nel binario
Il binario contiene anche percorsi di Setapp (`/Library/Application Support/Setapp/LaunchAgents/Setapp.app`), Adobe AIR (`~/Library/Application Support/Adobe/AIR/ELS`) e SDM (`~/Library/Preferences/SDMHelpData/Other`): sono casi speciali gestiti a mano.
