import CryptoKit
import Foundation
import MacCleanerCore

/// Operations that need administrator rights. The set is closed on purpose:
/// nothing outside this enum can be run as root by the app.
public enum AdminOperation: Sendable, Equatable {
    /// Delete files under the system folders listed in `AdminRunner.systemRoots`.
    case remove([URL])
    /// Move files under `AdminRunner.systemRoots` to the user's Trash, so they can be restored.
    case moveToTrash([URL])
    case freeRAM
    case flushDNS
    case reindexSpotlight
    case repairPermissions
    case runPeriodicScripts
    case thinLocalSnapshots
    case removeWiFiNetwork(String)
    case bootoutDaemon(label: String)
    /// Stop a daemon and, only if it stopped, move its plist (in /Library/LaunchDaemons) to the Trash.
    case removeDaemon(label: String, plist: URL)
    /// Ask macOS to fetch the latest XProtect definitions now.
    case updateXProtect
    /// Read-only: print the root-only facts the Protection checks need (see `SystemEvidence.shellCommand`).
    case collectSystemEvidence
    /// Move system files into a new folder of the system quarantine (`Quarantine.systemFolder/<id>`), then lock it.
    case quarantine([URL], id: UUID)
    /// Put a quarantined system item back into its original folder.
    case restoreQuarantined(id: UUID, name: String, into: URL)
    /// Delete a system quarantine folder for good.
    case deleteQuarantined(id: UUID)

    public var title: String {
        switch self {
        case .remove(let urls): "Eliminazione di \(urls.count) elementi di sistema"
        case .moveToTrash(let urls): "Spostamento nel Cestino di \(urls.count) elementi di sistema"
        case .freeRAM: "Liberare la RAM"
        case .flushDNS: "Svuotare la cache DNS"
        case .reindexSpotlight: "Reindicizzare Spotlight"
        case .repairPermissions: "Riparare i permessi della cartella Inizio"
        case .runPeriodicScripts: "Eseguire gli script di manutenzione"
        case .thinLocalSnapshots: "Liberare lo spazio eliminabile"
        case .removeWiFiNetwork(let name): "Dimenticare la rete \(name)"
        case .bootoutDaemon(let label): "Fermare \(label)"
        case .removeDaemon(let label, _): "Fermare e rimuovere \(label)"
        case .updateXProtect: "Aggiornare le definizioni XProtect"
        case .collectSystemEvidence: "Leggere le impostazioni di sistema per il controllo approfondito"
        case .quarantine(let urls, _): "Mettere in quarantena \(urls.count) elementi di sistema"
        case .restoreQuarantined(_, let name, _): "Ripristinare \(name) dalla quarantena"
        case .deleteQuarantined: "Eliminare un elemento dalla quarantena"
        }
    }
}

public enum AdminError: Error, Equatable, Sendable {
    case refused(String)
    case cancelled
    case failed(String)
    /// The helper ran, but some items could not be handled. `done` holds the
    /// paths that were (as `AdminRunner.helperPath(of:)` writes them).
    case itemsFailed(done: [String], failed: [String])
}

/// Runs an `AdminOperation` with a single macOS administrator password prompt.
///
/// Paths are validated before anything runs (inside `systemRoots`, not SIP
/// protected, symlinks resolved) and every argument is shell-quoted, so a
/// file name cannot inject commands.
///
/// Files are never touched by `rm` or `mv` with full paths: the password prompt
/// can stay open for a while, and a folder swapped for a symlink meanwhile
/// would send them elsewhere. Instead the root shell runs `mchelper`, which
/// opens each folder without following symlinks and works relative to it (see
/// `PinnedFileSystem`). The helper is first copied into a new folder only root
/// can write to and checked against the SHA-256 the app computed, so it cannot
/// be swapped between the check and the run.
public struct AdminRunner: Sendable {
    public static let systemRoots: [URL] = SystemRoots.paths.map { URL(fileURLWithPath: $0) }

    /// The helper inside the app bundle (Contents/MacOS/mchelper).
    public static var bundledHelper: URL? { Bundle.main.url(forAuxiliaryExecutable: "mchelper") }

    public let log: OperationLog?
    public let helper: URL?

    public init(log: OperationLog? = .standard, helper: URL? = AdminRunner.bundledHelper) {
        self.log = log
        self.helper = helper
    }

    /// The shell command for an operation, or an error if it is not allowed.
    /// `trash` is the folder `moveToTrash` moves items into (the user's Trash by default).
    public func command(for operation: AdminOperation, uid: uid_t = getuid(),
                        trash: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
        throws -> String {
        switch operation {
        case .remove(let urls):
            try Self.validateSystemItems(urls)
            return try helperCommand(["remove"] + Self.helperItems(urls))
        case .moveToTrash(let urls):
            try Self.validateSystemItems(urls)
            guard (try? trash.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let realTrash = Self.realPath(trash) else {
                throw AdminError.refused("Cestino non trovato: \(trash.path)")
            }
            // The helper picks "name 2", "name 3"… itself, so nothing in the Trash is replaced.
            return try helperCommand(["trash", realTrash, String(uid)] + Self.helperItems(urls))
        case .freeRAM:
            return "/usr/sbin/purge"
        case .flushDNS:
            return "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
        case .reindexSpotlight:
            return "/usr/bin/mdutil -E /"
        case .repairPermissions:
            return "/usr/sbin/diskutil resetUserPermissions / \(uid)"
        case .runPeriodicScripts:
            return "/usr/sbin/periodic daily weekly monthly"
        case .thinLocalSnapshots:
            return "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4"
        case .collectSystemEvidence:
            return SystemEvidence.shellCommand
        case .quarantine(let urls, let id):
            try Self.validateSystemItems(urls)
            let folder = Self.shellQuote(Quarantine.systemFolder + "/" + id.uuidString)
            // The folder is created by root right now, so the helper's owner
            // check (0) holds; then nothing in it may run or be read.
            return "/bin/mkdir -p -m 700 \(folder) || exit 1; "
                + (try helperCommand(["trash", Quarantine.systemFolder + "/" + id.uuidString, "0"] + Self.helperItems(urls)))
                    .replacingOccurrences(of: "exit $rc", with: "/bin/chmod -R 000 \(folder); /bin/chmod 700 \(folder); exit $rc")
        case .restoreQuarantined(let id, let name, let destination):
            guard PinnedFileSystem.isPlainName(name), let target = Self.realPath(destination),
                  SystemRoots.paths.contains(where: { target == $0 || target.hasPrefix($0 + "/") }) else {
                throw AdminError.refused("\(destination.path): fuori dalle cartelle di sistema consentite")
            }
            let folder = Quarantine.systemFolder + "/" + id.uuidString
            return "/bin/chmod -R u+rwX \(Self.shellQuote(folder)) || exit 1; "
                + (try helperCommand(["trash", target, "0", folder, name]))
                    .replacingOccurrences(of: "exit $rc", with: "/bin/rmdir \(Self.shellQuote(folder)) 2>/dev/null; exit $rc")
        case .deleteQuarantined(let id):
            return "/bin/chmod -R u+rwX \(Self.shellQuote(Quarantine.systemFolder + "/" + id.uuidString)) 2>/dev/null; "
                + (try helperCommand(["remove", Quarantine.systemFolder, id.uuidString]))
        case .updateXProtect:
            // `xprotect` exists from macOS 15; older systems take the softwareupdate route.
            return FileManager.default.isExecutableFile(atPath: "/usr/bin/xprotect")
                ? "/usr/bin/xprotect update" : "/usr/sbin/softwareupdate --background-critical"
        case .removeWiFiNetwork(let name):
            guard !name.isEmpty, name.count <= 64 else { throw AdminError.refused("nome rete non valido") }
            return "/usr/sbin/networksetup -removepreferredwirelessnetwork \(Self.wifiInterface()) \(Self.shellQuote(name))"
        case .bootoutDaemon(let label):
            try Self.validateLabel(label)
            return "/bin/launchctl bootout system/\(label)"
        case .removeDaemon(let label, let plist):
            try Self.validateLabel(label)
            guard Self.realPath(plist.deletingLastPathComponent()) == "/Library/LaunchDaemons" else {
                throw AdminError.refused("\(plist.path): non è in /Library/LaunchDaemons")
            }
            // bootout fails when the daemon is not loaded: that is fine, what
            // matters is that launchd no longer has it before the plist moves.
            let stop = "/bin/launchctl bootout system/\(label) 2>/dev/null; "
                + "if /bin/launchctl print system/\(label) >/dev/null 2>&1; then "
                + "echo \(Self.shellQuote("\(label) è ancora in esecuzione")) >&2; exit 1; fi"
            return "\(stop); " + (try command(for: .moveToTrash([plist]), uid: uid, trash: trash))
        }
    }

    /// Shell lines that run the helper as root: copy it where only root can
    /// write, check its hash, run it, clean up.
    func helperCommand(_ arguments: [String]) throws -> String {
        guard let helper, let data = try? Data(contentsOf: helper) else {
            throw AdminError.refused("helper per le operazioni di sistema non trovato")
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let copy = "\"$H/mchelper\""
        return "H=$(/usr/bin/mktemp -d /private/tmp/maccleaner-helper.XXXXXX) || exit 1; "
            + "if /bin/cp -- \(Self.shellQuote(helper.path)) \(copy) "
            + "&& [ \"$(/usr/bin/openssl dgst -sha256 -r \(copy) | /usr/bin/cut -c1-64)\" = '\(hash)' ]; "
            + "then \(copy) \(arguments.map(Self.shellQuote).joined(separator: " ")); rc=$?; "
            + "else echo 'helper modificato dopo il controllo' >&2; rc=1; fi; "
            + "/bin/rm -rf \"$H\"; exit $rc"
    }

    /// "<folder> <name>" pairs for the helper, with the folder's canonical path.
    static func helperItems(_ urls: [URL]) throws -> [String] {
        try urls.flatMap { url -> [String] in
            guard let folder = realPath(url.deletingLastPathComponent()) else {
                throw AdminError.refused("\(url.path): cartella non trovata")
            }
            return [folder, url.lastPathComponent]
        }
    }

    /// The path the helper reports for an item: its canonical folder plus its name.
    public static func helperPath(of url: URL) -> String? {
        realPath(url.deletingLastPathComponent()).map { "\($0)/\(url.lastPathComponent)" }
    }

    static func validateLabel(_ label: String) throws {
        guard label.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw AdminError.refused("label non valida")
        }
    }

    /// The path with every symlink resolved (unlike `resolvingSymlinksInPath`,
    /// this keeps "/private", as the helper expects).
    static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func validateSystemItems(_ urls: [URL]) throws {
        guard !urls.isEmpty else { throw AdminError.refused("nessun elemento") }
        let validator = SafeRemover(allowedRoots: systemRoots, mode: .dryRun, log: nil)
        for url in urls {
            if let error = validator.validate(url) { throw AdminError.refused("\(url.path): \(error)") }
            guard PinnedFileSystem.isPlainName(url.lastPathComponent) else {
                throw AdminError.refused("\(url.path): nome non valido")
            }
        }
    }

    /// Asks for the password and runs the operation. Blocks until done.
    /// Throws `itemsFailed` when the helper could not handle every item.
    public func run(_ operation: AdminOperation) throws {
        _ = try runCapturing(operation)
    }

    /// Like `run`, returning what the operation printed.
    @discardableResult
    public func runCapturing(_ operation: AdminOperation) throws -> String {
        let shell = try command(for: operation)
        let script = "do shell script \(Self.appleScriptString(shell)) with administrator privileges "
            + "with prompt \(Self.appleScriptString("MacCleaner: \(operation.title)")) without altering line endings"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let report = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let (done, failed) = Self.parseHelperReport(report)
        log?.recordAdmin(operation.title, ok: process.terminationStatus == 0 && failed.isEmpty,
                         detail: ([shell] + failed).joined(separator: " | "))
        guard process.terminationStatus == 0 else {
            if message.contains("-128") { throw AdminError.cancelled }
            throw AdminError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !failed.isEmpty { throw AdminError.itemsFailed(done: done, failed: failed) }
        return report
    }

    /// Splits the helper's "ok"/"err" lines into handled paths and failures.
    public static func parseHelperReport(_ text: String) -> (done: [String], failed: [String]) {
        var done: [String] = [], failed: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { continue }
            if fields[0] == "ok" { done.append(fields[1]) }
            if fields[0] == "err" { failed.append(fields.dropFirst().joined(separator: ": ")) }
        }
        return (done, failed)
    }

    /// Wraps a value in single quotes for /bin/sh, escaping inner quotes.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An AppleScript string literal.
    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func wifiInterface() -> String {
        // The Wi-Fi device is en0 on almost every Mac; networksetup tells us for sure.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "en0" }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where line.contains("Wi-Fi") || line.contains("AirPort") {
            if index + 1 < lines.count, lines[index + 1].hasPrefix("Device: ") {
                return String(lines[index + 1].dropFirst("Device: ".count))
            }
        }
        return "en0"
    }
}
