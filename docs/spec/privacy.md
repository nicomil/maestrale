# Privacy

Framework: `PrivacyScanning`, `PrivacyService`.

## Elementi per browser
| Browser | Elementi (tipi CMM) | Dove sono i dati |
|---|---|---|
| Safari | cronologia, cookie, cronologia download, schede dell'ultima sessione | `~/Library/Safari/History.db` (SQLite, tabelle `history_items`/`history_visits`), `~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies`, `~/Library/Safari/Downloads.plist`, stato delle schede in `~/Library/Containers/com.apple.Safari/Data/Library/Saved Application State` (`SafariTabsFromLastSessionFolderProvider`). Profili Safari multipli (`SafariProfileProvider`). Tutto richiede Full Disk Access. |
| Chrome (e derivati Chromium) | cronologia, cookie, download, password salvate, autofill, parole chiave di ricerca, motori di ricerca, schede dell'ultima sessione | `~/Library/Application Support/Google/Chrome/<Profilo>/`: `History` (tabelle `urls`, `visits`, `downloads`, `keyword_search_terms`), `Cookies`, `Login Data`, `Web Data` (`autofill`, `keywords`), cartella `Sessions` (o `Current Session`/`Last Session` nelle versioni vecchie, vedi `ChromeLegacyTabsFromLastSessionFolderProvider`). Profili letti da `Local State`. |
| Firefox | cronologia, cookie, download, password salvate, autofill | `~/Library/Application Support/Firefox/Profiles/<profilo>/`: `places.sqlite` (`moz_places`, `moz_historyvisits`, download in `moz_annos`), `cookies.sqlite`, `logins.json` + `key4.db`, `formhistory.sqlite`. Profili da `profiles.ini`. |

Regole comuni:
- Il browser deve essere chiuso: se è aperto, chiedere di chiuderlo (i database sono bloccati; CMM usa `PrivacyDatabaseLockStorage`).
- Si cancellano righe dai database con SQL (`DELETE`), poi `VACUUM`; non si cancellano i file interi (rompe il profilo).
- Le password salvate si contano e si cancellano soltanto, mai lette o mostrate.
- Si aggiunge Arc, Brave, Edge e Vivaldi trattandoli come Chromium con la loro cartella base.

## Altri elementi
| Elemento | Tipo CMM | Implementazione |
|---|---|---|
| Elementi recenti | `RecentItemsController`, `RecentItemRemover` | File `.sfl3`/`.sfl4` in `~/Library/Application Support/com.apple.sharedfilelist/` (documenti, app, server recenti). |
| Storico quarantena download | (in System Junk) | `~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2` (SQLite, tabella `LSQuarantineEvent`) (B). |
| Reti Wi‑Fi | `NetworkModelFactory`, `NetworkRemover` | Elenco con `networksetup -listpreferredwirelessnetworks en0`; rimozione con `networksetup -removepreferredwirelessnetwork` (richiede privilegi di amministratore). |
| Permessi delle app | `ApplicationsPermissionScanTaskFactory`, `ApplicationPermissionRemover` | Lettura da TCC in sola lettura non è possibile senza FDA; la revoca si fa con `tccutil reset <Servizio> <bundleID>` (B: `/usr/bin/tccutil`). |
