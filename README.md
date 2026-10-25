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
- Le categorie ad alto rischio non sono mai preselezionate. Gli elementi di sistema chiedono la password di amministratore e accettano solo un elenco chiuso di operazioni (`AdminOperation`).

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
| M6: Smart Care, menu bar, pianificazione | da fare |
