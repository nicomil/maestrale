# Space Lens, file grandi/vecchi, duplicati

Framework: `SpaceLensScanning`, `SpaceLensModule`, `OrganizeScanning`, `CloudStorageScanning`.

## Space Lens
- Modello ad albero: `SpaceLensEntityTree` di `SpaceLensFileSystemEntity` (nome, dimensione allocata, figli).
- Scansione a lotti (`BatchBasedEnumerator`, `BatchBasedScanner`) con progresso incrementale (`ScanProgressValue`).
- I file iCloud non scaricati hanno uno stato cloud (`CloudStatus`, strategia `SpaceLensCloudScannerStrategy`): si mostrano ma con dimensione locale 0. L'helper offre `evictUbiquitousItemAt:` per liberare la copia locale.
- Aggiornamento incrementale quando cambia una cartella (`SpaceLensFolderChanges`).
- Cancellazione pianificata (`SpaceLensDeletionPlanner`): gli elementi scelti vengono raggruppati e i figli di cartelle già scelte vengono ignorati.

Implementazione consigliata: `getattrlistbulk` (o `FileManager.enumerator` con `totalFileAllocatedSizeKey` precaricato), un task per volume, hard link contati una volta sola (per inode), pacchetti (`.app`, `.photoslibrary`) trattati come una foglia con dimensione totale. Visualizzazione sunburst o treemap in SwiftUI `Canvas`.

## File grandi e vecchi (`OrganizeScanning`)
- Enumerazione della home con regole di esclusione (`IgnoreRule`, `InternalIgnoreRules`, `ScanRules`): saltare `~/Library`, cartelle nascoste, bundle, cartelle di sviluppo (`node_modules`, `.git`) se richiesto.
- Ogni file ha un tipo di contenuto (`ContentKind`, `ContentKindEvaluator`: video, audio, immagini, archivi, documenti, immagini disco, altro) e metadati (`FileMetadataFetcher`, `ImageMetadataFetcher`, `MediaMetadataFetcher`, `QuickTimeMetadataFetcher`).
- Filtri: dimensione minima (default 50 MB), ultimo accesso più vecchio di N mesi (`kMDItemLastUsedDate` oppure data di accesso del file), tipo.

## Duplicati e foto simili
- Il binario contiene `CMImageHashForImage` (hash percettivo per immagini simili) e un enumeratore per la libreria Foto (`PhotoLibraryEnumerator`, `PhotosItemInfo`).
- Duplicati esatti: raggruppare per dimensione → hash dei primi e ultimi 64 KB → SHA-256 completo solo per i gruppi rimasti. Preselezionare tutti tranne il più recente o quello nella cartella "migliore" (non in Download).
- Foto simili: hash percettivo (dHash 64 bit) e distanza di Hamming ≤ 6, preselezione della foto più piccola o sfocata. La libreria Foto si tocca solo tramite PhotoKit (rimozione con conferma di sistema), mai cancellando file nel pacchetto `.photoslibrary`.

## Archiviazione cloud (`CloudStorageScanning`)
CMM integra Dropbox, Google Drive e OneDrive tramite le loro API per liberare spazio locale. Nella nostra app: solo il caso iCloud Drive (rimozione della copia locale con `evictUbiquitousItem`), il resto è fuori portata.
