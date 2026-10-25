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
