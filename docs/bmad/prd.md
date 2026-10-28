# PRD (Product Manager)

## Obiettivo
Rendere affidabili le funzioni di base segnalate (svuotare il Cestino, disinstallare un'app, aggiornamenti coerenti) e migliorare l'uso quotidiano (selezione multipla, avanzi più sicuri, schermata Protezione leggibile), senza allentare le regole di sicurezza del progetto: niente rimozioni fuori dalle cartelle consentite, elementi a rischio mai preselezionati, operazioni di sistema solo tramite `mshelper`.

## Epic 1: pulizia affidabile

### Storia 1.1: svuotare davvero il Cestino
Come utente, quando premo "Svuota" nel modulo Cestini voglio che gli elementi selezionati vengano eliminati, compresi file vuoti, cartelle vuote e file bloccati.

Criteri di accettazione
- Nel modulo Cestini la modalità "Sposta nel Cestino" non esiste: le scelte sono "Svuota" (eliminazione definitiva) e "Prova".
- Il pulsante si chiama "Svuota", la conferma dice che l'operazione è definitiva.
- Gli elementi di dimensione zero compaiono nell'elenco e vengono eliminati.
- Un file con flag `uchg` nel Cestino viene sbloccato ed eliminato; lo sblocco è attivo solo per questo modulo.
- Dopo la pulizia una nuova scansione mostra "Niente da pulire" se tutto è stato eliminato.
- La modalità predefinita delle Impostazioni resta valida per gli altri moduli.

### Storia 1.2: disinstallare anche le app di root
Come utente voglio che "Disinstalla" rimuova il bundle anche quando appartiene a root, chiedendo la password una sola volta.

Criteri di accettazione
- Un'app il cui bundle non è scrivibile dall'utente è marcata "password" (`needsHelper`) e viene rimossa tramite `AdminOperation.moveToTrash` o `.remove` secondo la modalità.
- Il bundle dell'app è sempre preselezionato, anche quando richiede la password; gli altri file seguono le regole attuali.
- Se la rimozione senza password del bundle fallisce per permessi, l'app ritenta una volta tramite l'helper invece di riportare un errore.
- La conferma avvisa quando macOS chiederà la password.
- Dopo una disinstallazione riuscita l'app sparisce dall'elenco.

## Epic 2: aggiornamenti coerenti

### Storia 2.1: elenco aggiornamenti sincronizzato con il disco
Come utente, dopo aver aggiornato un'app voglio che sparisca dall'elenco senza dover rilanciare il controllo.

Criteri di accettazione
- L'elenco rilegge le versioni installate quando la schermata viene mostrata, quando l'app torna in primo piano e dopo ogni azione "Aggiorna".
- Una voce resta solo se la versione installata è ancora più vecchia di quella disponibile (per Sparkle si confrontano i build, come nel controllo).
- Per l'App Store si scartano le versioni che richiedono un macOS più recente di quello in uso, e "Apri App Store" apre l'app App Store (link `macappstore://`), non il browser.
- Per Homebrew si scartano i cask la cui versione non è più nuova di quella dell'app installata (falsi positivi di `--greedy`).
- L'intestazione mostra l'ora dell'ultimo controllo.

## Epic 3: selezione multipla

### Storia 3.1: seleziona tutto / deseleziona tutto
Come utente voglio due comandi per selezionare o deselezionare tutti gli elementi visibili, in ogni schermata con caselle di selezione.

Criteri di accettazione
- Moduli a elenco (Pulizia sistema, Cestini, Allegati, Installer, File grandi, Duplicati, Immagini simili, Avanzi): comandi "Seleziona tutto" e "Deseleziona tutto" nell'intestazione, applicati agli elementi visibili con il filtro attivo; l'elemento "da tenere" di un gruppo di copie non viene mai selezionato.
- Space Lens: stessi comandi sopra l'elenco a destra, esclusi gli aggregati "N file piccoli".
- Disinstallazione: stessi comandi sull'elenco dei file dell'app.
- Privacy: stessi comandi sull'elenco delle voci.
- I comandi sono disattivati quando non cambiano nulla.

## Epic 4: avanzi più sicuri

### Storia 4.1: mostrare solo avanzi davvero orfani
Come utente voglio che "Avanzi di app rimosse" elenchi solo cartelle di app che non esistono più, e che mi avvisi quando un elemento potrebbe essere ancora in uso.

Criteri di accettazione
- Sono esclusi gli identificativi che corrispondono a un servizio `launchd` presente nei plist (`~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`) o caricato nella sessione (`launchctl list`), oltre alle esclusioni attuali (app installate, helper interni, processi, Launch Services).
- Ogni elemento mostra da quanto tempo non viene modificato. Un elemento modificato negli ultimi 30 giorni è a rischio alto, con la nota "forse ancora in uso".
- Niente è preselezionato (come oggi); la descrizione del modulo spiega i criteri.

## Epic 5: Protezione leggibile

### Storia 5.1: riorganizzare la schermata dei risultati
Come utente, dopo la scansione voglio capire a colpo d'occhio quanti problemi ci sono, di che tipo, e concentrarmi su una categoria alla volta.

Criteri di accettazione
- Sotto le schede di stato compare una barra di riepilogo con il filtro per gravità ("Pericoli e avvisi" predefinito, "Solo pericoli", "Tutto, con informazioni"), l'interruttore "Solo nuovi" e un campo di ricerca su titolo, ragioni e percorso.
- A sinistra un elenco delle categorie con il conteggio e il colore della gravità peggiore; "Tutte" in cima. A destra solo i risultati della categoria scelta, ordinati per gravità, poi i nuovi, poi per titolo.
- Ogni riga mostra icona di gravità, titolo, badge "Nuovo", la prima ragione e il percorso; un clic la espande con tutte le ragioni e i dettagli. Le azioni principali (Rimuovi, Quarantena, Termina, Apri Impostazioni, Aggiorna definizioni) restano sulla riga; Ignora, Fidati e Mostra nel Finder vanno in un menu.
- Il badge in barra laterale, Smart Care e lo scheduler continuano a funzionare come prima (stesse proprietà del modello).

## Fuori ambito
- Scaricare e installare aggiornamenti.
- Nuove fonti di avanzi (Steam, JetBrains, plugin audio).
- Modifiche a `mshelper`.
