# Brief (Analyst)

## Contesto
MacCleaner è un'app macOS personale (SwiftUI, Swift 6, macOS 14+) che replica le funzioni di CleanMyMac 5. Dopo la milestone M7 l'utente l'ha usata per una giornata e ha riportato sei problemi. Questo documento li ricostruisce con le prove trovate nel codice e nel registro `~/Library/Logs/MacCleaner/operations.log`.

## Problemi e cause

### 1. Il Cestino non si svuota
**Sintomo.** "Svuota" riporta successo ma i file restano nel Cestino.

**Prova.** Il registro del 27 ottobre alle 13:44 mostra 33 righe `trash ok` per elementi di `~/.Trash`. L'operazione eseguita è stata `FileManager.trashItem`: spostare nel Cestino un elemento che è già nel Cestino non lo rimuove.

**Causa.** `AppModel.clean` usa la modalità globale (`removalMode`, di default "Sposta nel Cestino") per tutti i moduli, compreso `TrashModule`, dove l'unica operazione sensata è l'eliminazione definitiva. Inoltre `RuleEngine.evaluate` scarta gli elementi di dimensione zero (file e cartelle vuote), che quindi non vengono mai eliminati, e i file bloccati (flag `uchg`) fanno fallire `removeItem`.

### 2. Disinstallazione incompleta (Slack)
**Sintomo.** Disinstallando Slack sono spariti i dati ma non `/Applications/Slack.app`.

**Prova.** Registro, 13:50: `refused failed("“Slack.app” couldn’t be moved to the trash because you don’t have permission to access it.")`. Sul disco `/Applications/Slack.app` è `root:wheel 755`.

**Causa.** `InstalledApp.isWritable` usa solo `isDeletableFile`, che guarda la cartella madre (`/Applications` è scrivibile dal gruppo admin). Spostare una cartella in un'altra cartella madre richiede però il permesso di scrittura sulla cartella stessa, che per un bundle di root manca. L'app viene quindi trattata come rimovibile senza password, e la rimozione fallisce invece di passare dall'helper privilegiato (`AdminOperation.moveToTrash`, che ammette `/Applications`). In più il bundle con `needsHelper` non è preselezionato, quindi anche quando la rilevazione è corretta l'utente può disinstallare "tutto tranne l'app".

### 3. Aggiornamenti: lista non aggiornata e falsi positivi
**Sintomo.** Dopo aver aggiornato un'app, resta nell'elenco "da aggiornare"; una voce indicava un aggiornamento che l'App Store non mostrava.

**Causa.** `UpdatesModel` non rilegge mai le versioni installate: l'elenco cambia solo con "Controlla di nuovo" o dopo `brew upgrade`. Per l'App Store la ricerca iTunes non considera `minimumOsVersion` e confronta solo le stringhe di versione; per Homebrew `brew outdated --greedy` segnala anche i cask che si aggiornano da soli (versione di brew vecchia, app già nuova). Il caso riportato è compatibile con il primo difetto: l'app era già aggiornata ma l'elenco non lo sapeva.

### 4. Manca "seleziona tutto / deseleziona tutto"
**Sintomo.** In Space Lens (elenco a destra), negli "Avanzi di app rimosse" e nelle altre schermate con selezione non c'è un comando per selezionare o deselezionare tutto.

**Causa.** Le viste espongono solo i toggle per riga e per gruppo. Space Lens usa una `List` con selezione nativa (⌘A funziona solo con il focus sulla lista, e non è scopribile).

### 5. Avanzi di app rimosse: sicurezza di ciò che viene mostrato
**Sintomo.** L'utente vuole la certezza che ciò che il modulo elenca sia davvero rimovibile.

**Analisi.** `OrphanLeftoversModule` considera orfana una cartella con nome a forma di bundle id che non appartiene a un'app installata (in `/Applications`, `~/Applications`, un livello di sottocartelle), a un suo helper, a un processo in esecuzione o a un'app nota a Launch Services. Mancano due segnali importanti: i servizi `launchd` (agent e daemon, anche senza app, come `com.google.Keystone`) e la data dell'ultimo uso della cartella. Un elemento modificato di recente è probabilmente ancora in uso da uno strumento a riga di comando.

### 6. Schermata Protezione illeggibile dopo la scansione
**Sintomo.** Al termine della scansione compare un unico elenco lunghissimo, difficile da capire.

**Analisi.** `ProtectionView` mostra tutte le categorie in sequenza in una sola `List`, ogni riga con tutte le ragioni, il percorso, i dettagli e fino a cinque pulsanti. Non c'è un modo per concentrarsi su una categoria, su una gravità o su ciò che è nuovo, e il filtro "Mostra anche le informazioni" è l'unico strumento di riduzione.

## Priorità
1. Cestino e disinstallazione: difetti funzionali che rendono inutili due funzioni di base.
2. Aggiornamenti: difetto di coerenza che fa perdere fiducia nei risultati.
3. Avanzi: rafforzare la sicurezza prima di rendere più facile selezionare tutto.
4. Selezione multipla e Protezione: usabilità.
