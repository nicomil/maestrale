# Esito di sviluppo e verifica (Dev + QA)

Data: 27 ottobre 2026, aggiornato il 28 ottobre 2026.

## Test automatici
| Suite | Comando | Esito |
|---|---|---|
| MacCleanerCore (regole, rimozione sicura, helper) | `swift test` nel pacchetto | 26 test, tutti verdi (3 nuovi: elementi vuoti del Cestino, sblocco dei file bloccati, nessuno sblocco fuori dalle cartelle consentite) |
| MacCleanerModules (app, aggiornamenti, avanzi, protezione) | `swift test` nel pacchetto | 103 test, tutti verdi (8 nuovi: aggiornamento ancora pendente per fonte, App Store e macOS minimo, parsing di `launchctl list`, classificazione per età, label launchd che proteggono gli avanzi) |
| MacCleanerTests (modelli dell'app) | `xcodebuild test -only-testing:MacCleanerTests` | 11 test, tutti verdi (5 nuovi: bundle preselezionato con password, secondo tentativo con password, seleziona tutto con filtro e copie da tenere, Space Lens senza aggregati, modalità effettiva del Cestino, filtro di Protezione) |

Build Debug dell'app: riuscita (prodotta dal comando di test).

## Verifica manuale
- App ricompilata e avviata; schermata Protezione con scansione reale: 45 avvisi e 71 informazioni su questo Mac. L'intestazione mostra i conteggi per gravità e i nuovi; la barra dei filtri, la colonna delle categorie (Avvio automatico 2, Applicazioni 9, Processi 33, Rete 1) e le righe compatte con azione principale e menu secondario sono al loro posto. Difetto trovato e corretto: senza il chevron di espansione i pulsanti slittavano a destra; ora lo spazio è sempre riservato.

## Storie e stato
| Storia | Stato | Note |
|---|---|---|
| S1 Cestino | fatta | `effectiveMode` forza l'eliminazione; `includeEmptyItems`; `unlocksItems` solo per il Cestino; interfaccia "Svuota" + "Solo prova" |
| S2 Disinstallazione app di root | fatta | `isWritable` corretto; bundle preselezionato; secondo tentativo con password per i rifiuti sotto `/Applications` e le altre cartelle di sistema |
| S3 Aggiornamenti | fatta | `refresh()` alla comparsa, al ritorno in primo piano e dopo ogni azione; `minimumOsVersion`; link `macappstore://`; filtro dei cask `--greedy` |
| S4 Seleziona tutto | fatta | moduli a elenco, Space Lens, Disinstallazione, Privacy |
| S5 Avanzi più sicuri | fatta | label launchd (plist e `launchctl list`); età e rischio per elemento |
| S6 Protezione | fatta | filtro per gravità, "Solo nuovi", ricerca; colonna categorie; righe compatte espandibili; menu secondario |
| S7 Feedback di Manutenzione (richiesta successiva al feedback d'uso) | fatta | `MaintenanceTask.run` restituisce un riepilogo misurato (cache RAM prima/dopo, istantanee contate, dimensione del database di Mail); `MaintenanceError.nothingToDo` per lo stato "niente da fare"; errori reali nella scheda. Test `SystemModulesTests.maintenanceSummariesTellWhatChanged` |
| S8 Versione e build negli Aggiornamenti | fatta | `AppUpdate.versionLine` mostra "0.65.2 (111) → 0.65.2 (113)" quando cambia solo il build (caso reale: cmux). Test `AppsTests.versionLineShowsBuildsWhenMarketingVersionsMatch` |
| S9 XProtect Remediator: falso "pericolo" | fatta | `status_code 20` arriva con "NoThreatDetected" e veniva letto come rilevamento; ora contano solo `status_message` e `subject`, e il modulo viene dal nome del processo quando manca nel JSON. Test `PostureTests.remediatorEventsAreParsed` (esteso) e `remediatorModuleComesFromTheProcessNameWhenTheEventLacksIt` |
| S11 Avanzamento universale | fatta | `ProgressCenter` (titolo, N di M, byte, elemento in corso, fase, tempo, "Interrompi") e `ProgressBanner` in fondo a ogni schermata; `SafeRemover.remove(progress:shouldContinue:)` riporta ogni elemento e si ferma su richiesta. Cablato in pulizia moduli e Cestino, Space Lens, Disinstallazione/Reset, Privacy, Manutenzione, rimozioni di Protezione. Test `SafeRemoverTests.progressReportsEveryItem`, `removalStopsWhenAsked`, `ProgressCenterTests` |
| S10 Attività: colonna azioni tagliata | fatta | le colonne sommavano 970 pt su 930 disponibili alla larghezza minima; ridotte (Processo 240, Memoria/Rete/Disco 80, Firma 120, azioni 90) |

## Cose da provare a mano (non automatizzabili qui)
1. Cestini: scansione, "Svuota", verifica che il Cestino sia vuoto anche con un file bloccato (Finder → Informazioni → Bloccato).
2. Disinstallazione di Slack: il bundle appare con il badge "password" già selezionato; "Disinstalla" chiede la password una volta e rimuove `/Applications/Slack.app`.
3. Aggiornamenti: aggiornare un'app, tornare su MacCleaner: la voce sparisce da sola.
