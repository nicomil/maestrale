# Helper privilegiato

Componenti CMM: `Contents/Library/LaunchServices/com.macpaw.CleanMyMac5.Agent`, `PrivilegedOperationsPerformerService`, `PrivilegedRoutines`, `IPCProtocol`.

## Cosa fa quello di CMM
- Installazione con autorizzazione (`authorizeWithPrompt:includeExecuteRights:`, `enableAgentWithBundleIdentifier:authorization:`) e rimozione (`uninstallPrivilegedAgentWithPrompt:bundleIdentifier:`).
- Comunicazione XPC via Mach service (`initWithMachServiceName:options:`, `listener:shouldAcceptNewConnection:`).
- Espone in pratica un FileManager root completo: `removeItemAt`, `moveItemAt`, `copyItemAt`, `replaceItemAt`, `truncateFileAt`, `createDirectoryAt`, `contentsOfDirectoryAt`, `enumeratorAt`, `attributesOfItemAtPath`, `isFileProtectedByRootlessAtPath` (SIP), `isFileRestrictedAtPath`, `tryToUnlockFileIfNeededAtPath:recursively:` (rimozione del flag `uchg`), `removeFileAndHandleLockAtPath`, `evictUbiquitousItemAt`.
- Esegue comandi arbitrari con output (`launchTaskAndGetOutput:arguments:suppressErrorOutput:`).

## Scelte per la nostra app (più ristretto, per sicurezza)
- Installazione con `SMAppService.daemon(plistName:)` (macOS 13+), l'utente approva in Impostazioni → Elementi di login.
- Mach service `it.nico.maccleaner.helper`. In `shouldAcceptNewConnection` si verifica il chiamante con `setCodeSigningRequirement` (stesso Team ID e bundle ID dell'app).
- **Nessuna operazione generica.** Protocollo XPC con poche funzioni tipizzate:
  - `trash(paths:)` e `remove(paths:)` solo se ogni percorso, dopo la risoluzione dei symlink, sta dentro una radice in allowlist (`/Library/Caches`, `/Library/Logs`, `/private/var/log`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`, `/Library/PrivilegedHelperTools`, `/Library/Application Support`, `/Applications`, `/Users/Deleted Users`) e non è protetto da SIP.
  - `runMaintenance(task:)` con un enum chiuso (`purge`, `flushDNS`, `reindexSpotlight`, `repairPermissions`, `periodic`), ognuno mappato su un comando fisso senza argomenti dall'esterno.
  - `launchctl(bootout label:)` solo per label già trovate dallo scanner.
- Ogni operazione viene scritta in un log (`/Library/Logs/MacCleaner/helper.log`) con chiamante, percorso e risultato.

## Implementazione attuale (M4)
Su questo Mac non c'è un certificato di firma (`security find-identity` non trova identità), e un demone `SMAppService` firmato ad-hoc non viene avviato da launchd. Per questo le operazioni da amministratore passano da `AdminRunner`:
- usa la richiesta password standard di macOS (`osascript … with administrator privileges`), una sola richiesta per operazione;
- accetta solo l'insieme chiuso `AdminOperation` (rimozione nelle cartelle di sistema ammesse, purge, DNS, Spotlight, permessi, script periodici, istantanee locali, reti Wi‑Fi, fermare un daemon);
- valida i percorsi con `SafeRemover` (radici ammesse, niente SIP, symlink risolti) prima di costruire il comando, e mette ogni argomento tra apici per la shell;
- registra ogni operazione nel log.

Quando ci sarà un certificato Apple Development si può aggiungere il demone descritto sopra senza cambiare l'interfaccia: basta un secondo backend per `AdminOperation`.
