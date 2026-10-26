# MacCleaner

App macOS personale per pulire il Mac, ispirata alle funzioni di CleanMyMac 5.
Le specifiche funzionali sono in `docs/spec/`, il piano completo in `docs/spec/README.md`.

## Requisiti
- macOS 14 o successivo, Xcode (anche se `xcode-select` punta ai Command Line Tools)
- XcodeGen (`brew install xcodegen`)

## Comandi
```bash
# Test della logica (regole, rimozione sicura)
cd Packages/MacCleanerKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# Progetto Xcode e build dell'app
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project MacCleaner.xcodeproj -scheme MacCleaner -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/MacCleaner.app

# Prova delle scansioni da Terminale (sola lettura, non rimuove nulla)
cd Packages/MacCleanerKit && swift build -c release --product mccli
.build/release/mccli junk|trash|large|duplicates|similar|orphans|apps|updates|privacy|launch|mail|installers|malware
```

## Sicurezza
- Di default i file vanno nel **Cestino**. C'è una modalità "Prova" che non rimuove nulla.
- `SafeRemover` rimuove solo dentro le cartelle elencate in `AllowedRoots`, risolve i symlink prima del controllo e rifiuta i file protetti da SIP.
- Ogni operazione è registrata in `~/Library/Logs/MacCleaner/operations.log`.
- Le categorie ad alto rischio non sono mai preselezionate. Gli elementi di sistema chiedono la password di amministratore e accettano solo un elenco chiuso di operazioni (`AdminOperation`); anche loro seguono la modalità scelta e, con "Sposta nel Cestino", finiscono nel Cestino invece di essere eliminati.
- I comandi eseguiti come amministratore entrano nella cartella dell'elemento, controllano che sia ancora quella verificata prima della richiesta della password e lavorano su `./nome`. Così uno scambio di cartelle con un symlink, mentre la finestra della password è aperta, non porta il comando altrove. Resta una finestra di pochi istanti solo sul controllo del Cestino di destinazione: per chiuderla del tutto servirebbe un helper privilegiato.
- Prima di cancellare cronologia, cookie o password da un database di un browser, ne viene salvata una copia completa nel Cestino. La copia è creata da SQLite (`VACUUM INTO`), include le modifiche recenti ancora nel file `-wal` e viene riletta prima di toccare l'originale; se non riesce, la pulizia non parte. La lettura dei database vede anche le modifiche nel file `-wal`.
- Duplicati: sono preselezionate solo le copie in Download, e prima della pulizia il programma ricontrolla che la copia che resta esista ancora e sia identica.
- Disinstallazione: i dati delle app (Application Support, Containers, Group Containers) non sono mai preselezionati. Durante la disinstallazione la lista delle app è bloccata, i file da rimuovere sono fissati al momento della conferma e i risultati di una ricerca superata da un'altra selezione vengono scartati.
- Installer: sono preselezionati solo `.dmg` non cifrati e `.pkg` di app già installate che macOS ha segnato come scaricati da internet (attributo di quarantena). Un'immagine creata dall'utente, cifrata o no, e i formati `.sparseimage`, `.img` e `.iso` non sono mai preselezionati.
- Pulizia sistema: le cache di un'app aperta sono escluse, anche quando stanno nel suo container (`~/Library/Containers/<id>/…`) o in cartelle come `<id>.ShipIt`. Il controllo è ripetuto subito prima della pulizia.
- Elementi di avvio: gli agenti, anche quelli in `/Library/LaunchAgents`, vengono fermati nella sessione dell'utente; i servizi di sistema con la password. Il plist va nel Cestino solo dopo aver verificato che launchd non lo abbia più caricato; altrimenti viene mostrato un errore e il plist resta al suo posto.
- Protezione: l'origine di un'estensione dei browser Chromium si basa su ciò che il browser ha registrato nelle preferenze del profilo, non sull'`update_url` del manifest, che chiunque può scrivere.

## Accesso completo al disco
Molte cartelle (Safari, profili dei browser, dati di altre app) sono leggibili solo con l'Accesso completo al disco: Impostazioni di Sistema → Privacy e sicurezza → Accesso completo al disco → aggiungi MacCleaner. Con la firma ad-hoc macOS può dimenticare il permesso a ogni nuova build: se i risultati spariscono, toglilo e rimettilo.

## Stato
| Milestone | Stato |
|---|---|
| Fase 0: rea + Ghidra | fatto |
| Fase 1: specifiche (statica + cattura dinamica) | fatto |
| M1: core, pulizia sistema, cestini | fatto (senza helper) |
| M2: Space Lens, file grandi e vecchi, duplicati, immagini simili | fatto |
| M3: disinstallazione, avanzi di app rimosse, aggiornamenti | fatto |
| M4: privacy, prestazioni, operazioni da amministratore | fatto (password macOS al posto del demone, vedi `docs/spec/helper.md`) |
| M5: protezione (euristiche), allegati di Mail, installer | fatto |
| M6: Smart Care, monitor nella barra dei menu, scansioni pianificate, impostazioni | fatto |
| Rifinitura UI/UX: icona, benvenuto, badge in barra laterale, filtro, annulla scansione, conferma con "Apri Cestino", menu contestuale | fatto |
