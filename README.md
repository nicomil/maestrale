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
```

## Sicurezza
- Di default i file vanno nel **Cestino**. C'è una modalità "Prova" che non rimuove nulla.
- `SafeRemover` rimuove solo dentro le cartelle elencate in `AllowedRoots`, risolve i symlink prima del controllo e rifiuta i file protetti da SIP.
- Ogni operazione è registrata in `~/Library/Logs/MacCleaner/operations.log`.
- Le categorie ad alto rischio non sono mai preselezionate. Quelle che richiedono privilegi di amministratore sono visibili ma disattivate finché non c'è l'helper.

## Stato
| Milestone | Stato |
|---|---|
| Fase 0: rea + Ghidra | fatto |
| Fase 1: specifiche (statica + cattura dinamica) | fatto |
| M1: core, pulizia sistema, cestini | fatto (senza helper) |
| M2: Space Lens, file grandi e vecchi, duplicati, immagini simili | fatto |
| M3: uninstaller, avanzi, updater | da fare |
| M4: privacy, performance, helper | da fare |
| M5: malware, Mail, immagini disco | da fare |
| M6: Smart Care, menu bar, pianificazione | da fare |
