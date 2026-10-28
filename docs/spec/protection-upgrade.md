# Protezione avanzata (M7): piano di upgrade orientato alla sicurezza

> Stato: tutte le fasi sono realizzate e coperte da test (`swift test` nel pacchetto, test dell'app con `xcodebuild test`).
> Differenze rispetto al piano, decise durante l'implementazione:
> - `sfltool dumpbtm` funziona senza password su macOS recenti, quindi i login item sono nella scansione standard.
> - Le app Mac App Store sono riconosciute dal certificato foglia (OID 1.2.840.113635.100.6.1.9) e trattate come verificate; le app notarizzate aggiornate da sole, che non hanno più l'attributo di quarantena, non vengono segnalate.
> - `eval "$(brew shellenv)"` e gli hook degli strumenti di sviluppo nei file di shell non sono segnalati; `eval`, `nohup`, `osascript -e` e `python -c` sono avvisi, `curl | sh`, base64 e cartelle temporanee sono pericoli.
> - I processi e i programmi nelle cartelle nascoste dei tool di sviluppo (`~/.pyenv`, `~/.local`, …) sono informativi, non avvisi.
> - XProtect Remediator: su macOS 27 gli eventi strutturati non compaiono nel log; si contano le esecuzioni dei moduli `XProtectRemediator*` e si leggono gli eventi JSON dove ancora presenti.
> - La quarantena di sistema riusa il comando `trash` di `mshelper` verso una cartella creata da root, seguito da `chmod -R 000`; ripristino ed eliminazione sono operazioni dedicate.
> - La schermata Attività e il monitor nella barra dei menu campionano con `ProcessSampler`; la scansione standard include tre campioni a un secondo.

Obiettivo: trasformare la schermata "Protezione" da controllo euristico su firme ed estensioni a un vero strumento di triage, equivalente (e superiore) a "apro Gestione attività, guardo i processi sospetti, lancio CCleaner". Deve rispondere a quattro domande:

1. **Cosa si avvia da solo** su questo Mac, e da quando?
2. **Cosa sta girando adesso**, e chi consuma CPU, RAM, rete e disco in modo anomalo?
3. **C'è traccia di malware conosciuto** (firme YARA aperte, hash noti, tecniche di persistenza tipiche)?
4. **Le difese di macOS sono accese** e configurate bene?

Tutto resta coerente con la filosofia dell'app: niente preselezioni sugli elementi a rischio, ogni segnalazione spiega il motivo, nessuna rimozione senza conferma, operazioni di sistema solo tramite l'insieme chiuso `AdminOperation` e `mshelper`.

## Stato attuale (M5/M6)

| Area | Cosa c'è | Cosa manca |
|---|---|---|
| Persistenza | LaunchAgents (utente e `/Library`), LaunchDaemons, firma e posizione del programma, label `com.apple.*` fasulle | login item / background item (BTM), cron, file di avvio della shell, profili di configurazione, certificati radice, estensioni di sistema e kext, Safari e Firefox, dirottamento homepage e ricerca, `/etc/hosts`, proxy e DNS, `DYLD_INSERT_LIBRARIES`, permessi TCC |
| App | firma mancante o non valida | app senza quarantena e non notarizzate (Gatekeeper aggirato con `xattr -c`), provenienza dei download |
| Browser | estensioni Chromium con `<all_urls>` o fuori dallo store | Safari, Firefox, homepage, motore di ricerca, startup URL |
| Processi | nessun controllo | inventario con firma, posizione, utente, padre; CPU, RAM, I/O disco, rete per processo; ascolto su porte; miner |
| Firme | nessuna | YARA (regole aperte), hash MalwareBazaar, esito XProtect Remediator |
| Difese | Gatekeeper, SIP, firewall, versione XProtect | FileVault, modalità invisibile, aggiornamenti automatici, accesso remoto, condivisione schermo, login automatico, account amministratore, ospite, impostazioni Safari |
| Storico | lista "ignorati" in UserDefaults | baseline dell'ultima scansione e differenza ("nuovo da ieri"), rapporto esportabile |
| Test | nessun test su `MalwareScanner` | fixture e parser testati, firma iniettabile |

## Principi di progettazione

- **Ogni controllo è un'unità** (`ProtectionCheck`) con nome, categoria, requisiti (nessuno / Accesso completo al disco / password) e un metodo `run() -> [Finding]`. Lo scanner è la somma dei controlli; ogni controllo ha test propri con fixture su disco temporaneo.
- **Il risultato è una prova, non un verdetto.** `Finding` porta: categoria, gravità (`info`/`warning`/`danger`), titolo, percorso, elenco di motivi, *evidenze* grezze (riga del plist, riga di `lsof`, permesso del manifest), azione consigliata (nessuna, disattiva avvio, Cestino, quarantena, apri Impostazioni) e data di prima comparsa.
- **Differenza rispetto alla baseline.** Dopo ogni scansione si salva un'istantanea (JSON in `~/Library/Application Support/Maestrale/protection/last-scan.json`). La schermata evidenzia "Nuovo dall'ultimo controllo": per un Mac che "fa sempre casini" la novità è il segnale più utile.
- **Tutto ciò che si legge è dato ostile.** Manifest, plist, script di shell, output di comandi, regole YARA scaricate: si parsano con limiti di dimensione, non si eseguono mai, non si seguono istruzioni contenute nei file. Nessun accesso di rete automatico: gli aggiornamenti di regole e hash sono scaricati dall'utente, con checksum mostrato.
- **Privilegi minimi.** La maggior parte dei controlli gira senza password (il malware su macOS vive quasi sempre nello spazio utente). Una sola operazione privilegiata *di sola lettura* (`.collectSystemEvidence`) raccoglie in un colpo ciò che serve root: TCC di sistema, `sfltool dumpbtm`, crontab di root, profili di dispositivo, `lsof` di tutti gli utenti. Niente comandi con argomenti dall'esterno.
- **Falsi positivi gestiti, non nascosti.** Oltre a "Ignora" per singolo elemento: elenco di Team ID fidati, allowlist per i gestori di pacchetti, e un livello "Mostra anche le informazioni" spento di default.

## Fasi

Ordine per rapporto valore/costo. Ogni fase è rilasciabile da sola.

### Fase 0: fondamenta e test

- Estrarre da `MalwareScanner` il protocollo `ProtectionCheck` e il modello `Finding` esteso (categoria, evidenze, azione, `firstSeen`). `MalwareFinding` resta come typealias per non rompere `ProtectionView`.
- Rendere iniettabile la verifica delle firme (`CodeSignatureEvaluator`), così i test non dipendono dai binari del Mac che esegue i test.
- Baseline: `ProtectionBaseline` salva e confronta gli `id` dei finding; espone `isNew`.
- Test: fixture con plist di launch agent in cartelle temporanee, `manifest.json` ed estensioni Chromium con e senza `from_webstore`, programma in `/tmp`, label `com.apple.*` fuori da `/System`. Oggi questi comportamenti non hanno nessun test.
- `mscli malware` stampa anche categoria ed evidenze; aggiungere `mscli processes` e `mscli posture`.

### Fase 1: postura delle difese (costo basso, valore alto)

Controlli aggiuntivi in `ProtectionStatus`, tutti senza password:

| Controllo | Fonte | Segnalazione |
|---|---|---|
| FileVault | `fdesetup status` | disattivato → warning |
| Firewall modalità invisibile e blocco connessioni in entrata | `socketfilterfw --getstealthmode`, `--getblockall` | consiglio |
| Aggiornamenti automatici (sistema, XProtect, critici) | `/Library/Preferences/com.apple.SoftwareUpdate.plist` chiavi `AutomaticallyInstallMacOSUpdates`, `ConfigDataInstall`, `CriticalUpdateInstall` | spento → warning |
| Versione macOS rispetto all'ultima pubblicata | `ProcessInfo.operatingSystemVersion`; confronto opzionale con il JSON pubblico di Apple (`gdmf.apple.com/v2/pmv`), solo su richiesta | arretrato → warning |
| Login automatico | `/Library/Preferences/com.apple.loginwindow` chiave `autoLoginUser` | attivo → warning |
| Accesso remoto (SSH) e condivisione schermo | `launchctl print system/com.openssh.sshd`, `…/com.apple.screensharing` | attivi → info con spiegazione |
| Account amministratore | `dscl . -read /Groups/admin GroupMembership` | più di un amministratore non riconosciuto → warning |
| Account ospite | `/Library/Preferences/com.apple.loginwindow` chiave `GuestEnabled` | attivo → info |
| Gatekeeper "da qualsiasi origine" | `spctl --status` già letto, più `defaults read com.apple.systempolicy.control` | abilitato → danger |
| Safari "apri i file sicuri dopo il download" | `com.apple.Safari` `AutoOpenSafeDownloads` (richiede Accesso completo al disco) | attivo → warning |
| XProtect Remediator: ultima esecuzione e rilevamenti | `log show --predicate 'subsystem == "com.apple.XProtectFramework.PluginAPI"' --last 7d` | rilevamenti → danger; nessuna esecuzione da 7 giorni → warning |

Ogni riga ha un pulsante "Apri Impostazioni" con il deep link `x-apple.systempreferences:` giusto. Nuova `AdminOperation.updateXProtect` (`xprotect update`, senza argomenti) per forzare l'aggiornamento delle definizioni.

### Fase 2: persistenza completa

Nuovi `ProtectionCheck`, tutti con la stessa logica di firma/posizione già usata per i launch item:

- **Login item e background item (BTM).** Senza password: `Contents/Library/LoginItems/*.app` dentro le app installate e i `SMAppService` registrati; con password: `sfltool dumpbtm` (parser testato su output campione). Elementi il cui eseguibile non esiste più, non firmato o in posizione insolita.
- **Cron e at.** `crontab -l` dell'utente; con password `/usr/lib/cron/tabs/*` e `/var/at/jobs`. Qualsiasi voce è almeno info; `curl … | sh`, `base64`, `eval`, percorsi nascosti → danger.
- **File di avvio della shell.** `~/.zshenv`, `~/.zprofile`, `~/.zshrc`, `~/.bash_profile`, `~/.bashrc`, `~/.profile`, `/etc/zshenv`, `/etc/zprofile`, `/etc/zshrc`, `/etc/profile`. Segnalare righe con download ed esecuzione, `eval`, codifiche base64, `nohup`, percorsi in `/tmp` o cartelle nascoste; mostrare la riga come evidenza. File modificati negli ultimi 30 giorni → info "controlla".
- **Profili di configurazione.** `profiles list -output stdout-xml` (utente) e `profiles show -type configuration` con password. Payload DNS, filtro contenuti web, proxy, certificati, restrizioni → danger se non installati da un MDM noto (il Mac di un privato non dovrebbe averne).
- **Certificati radice aggiunti.** `security dump-trust-settings -d` (amministratore) e `security dump-trust-settings` (utente), più `security find-certificate -a -p /Library/Keychains/System.keychain`. Qualsiasi radice fidata non Apple → danger (abilita intercettazione HTTPS).
- **Estensioni di sistema e kext.** `systemextensionsctl list`, `kmutil showloaded --list-only` → non Apple elencate con firma; non firmate → danger.
- **Estensioni Safari e Firefox.** Safari: `pluginkit -mAvvv -p com.apple.Safari.extension` ed `Extensions.plist` nel container di Safari (Accesso completo al disco). Firefox: `extensions.json` in ogni profilo. Stesse regole di Chromium (tutti i siti, fuori dallo store).
- **Dirottamento del browser.** Chromium: `homepage`, `session.startup_urls`, `default_search_provider_data` nelle `Preferences`; Safari: `HomePage` e motore di ricerca nel plist. Motore di ricerca non tra quelli noti (Google, Bing, DuckDuckGo, Ecosia, Yahoo, Qwant, Startpage) → danger.
- **Rete di sistema.** `/etc/hosts` con voci diverse da localhost → warning con le righe; `networksetup -getwebproxy`, `-getsecurewebproxy`, `-getautoproxyurl` per ogni servizio → proxy o PAC attivi → danger; `scutil --dns` con resolver non del router né noti (1.1.1.1, 8.8.8.8, 9.9.9.9…) → warning.
- **Iniezione di librerie.** `EnvironmentVariables.DYLD_INSERT_LIBRARIES` nei plist di launchd, `launchctl getenv DYLD_INSERT_LIBRARIES` → danger.
- **Permessi TCC.** `~/Library/Application Support/com.apple.TCC/TCC.db` (Accesso completo al disco) e, con password, quello di sistema. Elencare chi ha Accessibilità, Monitoraggio input (keylogger), Registrazione schermo, Accesso completo al disco, Automazione. App non firmata o non notarizzata con uno di questi → danger; le altre → info "verifica che ti serva".
- **Provenienza dei download.** `com.apple.LaunchServices.QuarantineEventsV2` (SQLite, Accesso completo al disco): app installate negli ultimi 30 giorni con URL di origine; app in `/Applications` senza attributo di quarantena e non notarizzate → warning "Gatekeeper aggirato".

### Fase 3: processi e risorse (la "Gestione attività" con giudizio)

Nuova schermata **Attività** nel gruppo Protezione, campionata ogni 2 secondi finché è aperta, più uno snapshot singolo dentro la scansione.

- **Inventario** con `libproc` (`proc_listpids`, `proc_pidpath`, `proc_pidinfo` con `PROC_PIDTBSDINFO` e `PROC_PIDTASKINFO`): pid, padre, utente, percorso, avvio. Firma e posizione con lo stesso `CodeSignatureEvaluator` (cache per percorso).
- **Risorse** con `proc_pid_rusage` (`RUSAGE_INFO_V4`): CPU come differenza di `ri_user_time`+`ri_system_time` tra campioni, RAM `ri_phys_footprint`, disco `ri_diskio_bytesread`/`byteswritten`. Rete per processo da `nettop -x -P -L 1 -J bytes_in,bytes_out` (parser testato); connessioni e porte in ascolto da `lsof -i -n -P -F` (senza password mostra i processi dell'utente, che sono quelli che contano).
- **Euristiche** (ogni una → motivo esplicito):
  - non firmato o ad-hoc e non Apple, in `/tmp`, `/Users/Shared`, Downloads, cartella nascosta → warning/danger;
  - eseguibile cancellato dopo l'avvio (percorso che non esiste più) → danger;
  - nome che imita un processo di sistema (`kernel_task`, `WindowServer`, `mds`…) ma fuori da `/System` e `/usr` → danger;
  - CPU sopra l'80% per tre campioni consecutivi da un processo non Apple → warning; se ha anche connessioni verso porte tipiche di mining (3333, 4444, 5555, 7777, 14444) o `stratum` → danger;
  - in ascolto su tutte le interfacce da parte di un processo non Apple non notarizzato → warning;
  - connessioni verso IP grezzi su porte insolite (IRC 6667, 1337, 4444) → warning;
  - figlio di `sh`/`osascript`/`python` avviato da un launch item → info con collegamento all'elemento di avvio.
- **Azioni**: "Mostra nel Finder", "Vai all'elemento di avvio" se il percorso corrisponde a un finding di persistenza, "Termina" (`SIGTERM`, solo processi dell'utente), "Termina e quarantena" (ferma, disattiva l'avvio, sposta in quarantena). Niente `kill` di processi root: si passa per `bootoutDaemon` già esistente.
- Il **monitor nella barra dei menu** mostra un punto arancione quando un processo non Apple supera l'80% di CPU per più di un minuto o un processo sconosciuto apre una porta in ascolto.

### Fase 4: azioni, quarantena, rapporto, automazione

- **Quarantena** come alternativa al Cestino per i finding `danger`: cartella `~/Library/Application Support/Maestrale/Quarantine/<uuid>/` con `manifest.json` (percorso originale, motivo, data, hash), file spostato con `renameatx_np(RENAME_EXCL)`, permessi `0000` e attributo di quarantena aggiunto. Per i file di sistema: nuova operazione `quarantine` in `mshelper`, destinazione `/Library/Application Support/Maestrale/Quarantine` scrivibile solo da root. Schermata "Quarantena" con ripristino ed eliminazione definitiva.
- **Sequenza di rimozione sicura** per un elemento con avvio automatico: termina il processo → bootout → verifica che launchd non lo abbia più → quarantena del plist e del programma → nuova scansione. Se un passo fallisce, ci si ferma e si spiega.
- **Rapporto** esportabile (Markdown e testo) con postura, finding per categoria con evidenze, processi anomali, novità dall'ultima scansione: serve a chi aiuta un parente a distanza.
- **Smart Care**: la card Protezione mostra "N nuovi" e il numero di `danger`; il pulsante avvia la scansione completa inclusa quella dei processi.
- **Scheduler**: la scansione pianificata esegue anche Protezione e manda una notifica solo per i finding nuovi di gravità `danger` (mai per quelli già noti o ignorati).

### Fase 5: firme aperte (YARA e hash)

L'unica fase con una dipendenza esterna, per questo è ultima.

- **libyara** come target C di SwiftPM dentro `Packages/MaestraleKit` (sorgenti di YARA 4.5, licenza BSD-3), compilato senza OpenSSL (modulo `hash` escluso, modulo `macho` incluso). Alternativa di ripiego se la compilazione dà problemi: usare l'eseguibile `yara` di Homebrew quando presente, con la funzione marcata "non disponibile" altrimenti.
- **Regole**: pacchetto YARA-Forge "core" filtrato alle regole macOS (raccoglie Elastic, Neo23x0 signature-base e altri, con le rispettive licenze riportate in `docs/`). Il file è scaricato dall'utente dal pulsante "Aggiorna regole", verificato con lo SHA-256 mostrato, salvato in `~/Library/Application Support/Maestrale/rules/`; nessun download automatico.
- **Ambito della scansione**, per tenerla sotto i due minuti: programmi dei launch item, eseguibile principale delle app, Downloads, `~/Library/Application Support` (solo Mach-O e script non firmati), `/tmp`, `/Users/Shared`, `/Library/Application Support`. Solo file Mach-O, script di shell, Python, JavaScript e AppleScript; limite 50 MB per file; cache `percorso+dimensione+mtime → esito` per non riscansionare.
- **Hash noti**: esportazione CSV di MalwareBazaar con tag `macos`, stessa procedura di download manuale; confronto SHA-256 sui file già aperti per YARA, nessun costo aggiuntivo.
- Un match YARA o hash è `danger` con nome della regola e fonte come evidenza; l'azione proposta è la quarantena, mai la cancellazione.

## Requisiti di accesso per controllo

| Richiede | Controlli |
|---|---|
| Niente | launch item, app, Chromium, Firefox, postura (tranne Safari), shell, cron utente, profili utente, certificati, estensioni di sistema, hosts, proxy, DNS, processi e rete dell'utente, YARA sui file dell'utente |
| Accesso completo al disco | Safari (estensioni, homepage, impostazioni), TCC utente, QuarantineEvents, Mail |
| Password (una sola richiesta, sola lettura) | BTM completo, crontab di root, profili di dispositivo, TCC di sistema, `lsof` di tutti gli utenti, `xprotect update` |

La scansione standard non chiede mai la password. Un pulsante "Controllo approfondito (password)" esegue in più `.collectSystemEvidence`.

## Struttura del codice

```
Packages/MaestraleKit/Sources/MaestraleModules/Protection/
  ProtectionCheck.swift        protocollo, Finding, categorie, requisiti
  CodeSignature.swift          CodeSignatureEvaluator (estratto da MalwareScanner) + cache
  ProtectionBaseline.swift     istantanea e differenza
  ProtectionScanner.swift      orchestrazione, parallelismo, timeout per controllo
  Checks/
    LaunchItemsCheck.swift     (oggi in MalwareScanner)
    AppsSignatureCheck.swift
    BrowserExtensionsCheck.swift  Chromium + Safari + Firefox
    BrowserHijackCheck.swift
    LoginItemsCheck.swift
    CronAndShellCheck.swift
    ProfilesCheck.swift
    TrustedRootsCheck.swift
    SystemExtensionsCheck.swift
    NetworkConfigCheck.swift   hosts, proxy, DNS
    TCCCheck.swift
    QuarantineEventsCheck.swift
    PostureCheck.swift
    XProtectCheck.swift
    YaraCheck.swift / KnownHashesCheck.swift
  Processes/
    ProcessInventory.swift     libproc
    ResourceSampler.swift      rusage, nettop, lsof (parser separati e testati)
    ProcessHeuristics.swift
  Quarantine.swift
  Report.swift
Packages/MaestraleKit/Sources/CYara/                 (fase 5)
Packages/MaestraleKit/Tests/MaestraleModulesTests/Protection/
  fixture per ogni check + output campione di sfltool, lsof, nettop, profiles, dump-trust-settings
App/
  ProtectionView.swift         raggruppa per categoria, filtro "nuovi", evidenze espandibili
  ActivityView.swift           tabella processi (CPU/RAM/disco/rete), badge firma, azioni
  QuarantineView.swift
```

`mshelper`: aggiungere l'operazione `quarantine` (sposta sotto la cartella di quarantena di root con `RENAME_EXCL`, senza seguire symlink). `AdminOperation`: `.collectSystemEvidence`, `.updateXProtect`, `.quarantine([URL])`.

## Cosa resta fuori (per scelta)

- Monitor in tempo reale del file system (Endpoint Security richiede un entitlement Apple che un'app firmata ad-hoc non ha).
- Firewall applicativo o blocco di connessioni (Network Extension, stesso problema).
- Scansione completa del disco con YARA: troppo lenta e con troppi falsi positivi; si scansionano i posti dove il malware vive.
- Database proprietari (Moonlock, VirusTotal con chiave): si potrà aggiungere "cerca l'hash su VirusTotal" come link che apre il browser, senza chiamate API.
- Temperatura e sensori: niente API pubbliche.

## Verifica

- Test unitari per ogni check con fixture, inclusi casi limite (plist malformati, manifest giganti, output di comandi vuoti o troncati).
- Test del campionatore dei processi sul processo di test stesso e su un `/bin/sleep` copiato in una cartella temporanea nascosta (deve risultare "cartella nascosta, non firmato").
- Test di `PinnedFileSystem` per la quarantena con lo scambio di symlink, come già fatto per Cestino ed eliminazione.
- Prova manuale con un "malware finto": launch agent in `~/Library/LaunchAgents` che avvia uno script in `/tmp`, estensione Chromium caricata non pacchettizzata, riga `curl | sh` commentata in `~/.zshrc` di prova, profilo DNS di test. Tutti devono comparire come `danger` con il motivo giusto e sparire dopo la quarantena.
- `mscli malware`, `mscli processes` e `mscli posture` per confrontare l'esito su più Mac senza l'interfaccia.

## Stima

| Fase | Dimensione | Note |
|---|---|---|
| 0 Fondamenta | media | prerequisito delle altre |
| 1 Postura | piccola | subito utile |
| 2 Persistenza | grande | molti parser, ognuno piccolo |
| 3 Processi | grande | nuova schermata, campionamento |
| 4 Azioni e rapporto | media | tocca `mshelper` |
| 5 YARA | media-grande | rischio di build della dipendenza |
