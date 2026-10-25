# Cestini, Mail, immagini disco, download

Framework: `TrashJunkScanning`, `MailJunkScanning`, `UnusedDiskImagesScanning`, `DownloadsScanning`.
Legenda come in `system-junk.md`.

## Cestini (`TrashJunkScanning`)
| Categoria | Task CMM | Percorsi | Condizioni | Rischio | Helper | Fonte |
|---|---|---|---|---|---|---|
| Cestino utente | `CMTrashesScanTask` | `~/.Trash` | Serve Full Disk Access. Lo svuotamento è definitivo. | alto | no | T |
| Cestini dei volumi | `CMMountedTrashesScanTask` | `/Volumes/*/.Trashes/<uid>` | Solo volumi montati e scrivibili (`mountedVolumeURLsIncludingResourceValuesForKeys:`). | alto | no | B |
| Cestino di Mail | `CMMailTrashScanTask` | Caselle "Deleted Messages"/"Trash" in `~/Library/Mail/V*/` | Modelli `MailTrashModel` e `MailTrashAttachmentModel`. | alto | no (FDA) | T |

## Allegati Mail (`MailJunkScanning`, task `CMMailTask`)
- Percorsi: `~/Library/Mail/V*/**/Attachments/*` e `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/*`.
- Condizione: rimuovere solo la copia locale; il messaggio sul server resta, Mail riscarica l'allegato quando lo si riapre (vale per IMAP/Exchange, non per POP).
- Rischio medio. Serve Full Disk Access.

## Immagini disco inutilizzate (`CMUnusedDiskImagesScanTask`)
- Ricerca di `.dmg`, `.iso`, `.sparseimage`, `.sparsebundle` nelle cartelle utente (Download, Scrivania, Documenti) tramite Spotlight (`kMDItemContentType == com.apple.disk-image*`).
- Condizioni: escludere immagini montate e quelle usate da Time Machine; segnalare se l'app contenuta è già installata in `/Applications` (stessa app, versione uguale o superiore).
- Rischio medio. Nessun helper.

## Download (`DownloadsScanning`)
| Fonte | Task CMM | Dove legge l'elenco | Fonte |
|---|---|---|---|
| Safari | `CMSafariDownloadsScanTask` | `~/Library/Safari/Downloads.plist` (FDA) | T |
| Chrome | `CMChromeDownloadsScanTask` | `~/Library/Application Support/Google/Chrome/<Profilo>/History`, tabella `downloads` (SQLite, da copiare prima di leggere) | B (percorso base) |
| Slack | `CMSlackDownloadsScanTask` | `~/Library/Application Support/Slack/storage/root-state.json` (team e download) | B |

- I risultati sono raggruppati per app → account/profilo → file (`DownloadsApplicationModel`, `DownloadsAccountModel`, `DownloadsItemModel`).
- Si mostrano solo i file ancora esistenti, con data di download e URL di origine. Nessuna preselezione.
- In più, la cartella `~/Downloads` va trattata come "file vecchi" in Space Lens (vedi `space-lens.md`).
