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
        }
    }
}

public enum AdminError: Error, Equatable, Sendable {
    case refused(String)
    case cancelled
    case failed(String)
}

/// Runs an `AdminOperation` with a single macOS administrator password prompt.
///
/// Paths are validated before anything runs (inside `systemRoots`, not SIP
/// protected, symlinks resolved) and every argument is shell-quoted, so a
/// file name cannot inject commands.
public struct AdminRunner: Sendable {
    public static let systemRoots: [URL] = [
        "/Library/Caches", "/Library/Logs", "/private/var/log", "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools", "/Library/Application Support", "/Library/Preferences",
        "/Library/Audio/Plug-Ins", "/Library/Internet Plug-Ins", "/Library/PreferencePanes",
        "/Library/Screen Savers", "/Library/QuickLook", "/Library/Spotlight", "/Applications", "/Users/Deleted Users",
    ].map { URL(fileURLWithPath: $0) }

    public let log: OperationLog?

    public init(log: OperationLog? = .standard) {
        self.log = log
    }

    /// The shell command for an operation, or an error if it is not allowed.
    /// `trash` is the folder `moveToTrash` moves items into (the user's Trash by default).
    public func command(for operation: AdminOperation, uid: uid_t = getuid(),
                        trash: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
        throws -> String {
        switch operation {
        case .remove(let urls):
            try Self.validateSystemItems(urls)
            return try urls.map { url in
                try Self.insideFolder(of: url) { "/bin/rm -rf -- \($0)" }
            }.joined(separator: " && ")
        case .moveToTrash(let urls):
            try Self.validateSystemItems(urls)
            guard (try? trash.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let realTrash = Self.realPath(trash) else {
                throw AdminError.refused("Cestino non trovato: \(trash.path)")
            }
            let quotedTrash = Self.shellQuote(realTrash)
            // `mv -n` never overwrites; names are made unique beforehand so nothing in the Trash is replaced.
            // Right before each move the Trash is checked again, and afterwards the item must be gone.
            return try Self.trashDestinations(urls, trash: URL(fileURLWithPath: realTrash)).map { pair in
                try Self.insideFolder(of: pair.source) { item in
                    "[ \"$(cd -P -- \(quotedTrash) && pwd -P)\" = \(quotedTrash) ] && /bin/mv -n -- \(item) "
                        + "\(Self.shellQuote(pair.destination.path)) && [ ! -e \(item) ] && [ ! -L \(item) ]"
                }
            }.joined(separator: " && ")
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
        case .removeWiFiNetwork(let name):
            guard !name.isEmpty, name.count <= 64 else { throw AdminError.refused("nome rete non valido") }
            return "/usr/sbin/networksetup -removepreferredwirelessnetwork \(Self.wifiInterface()) \(Self.shellQuote(name))"
        case .bootoutDaemon(let label):
            try Self.validateLabel(label)
            return "/bin/launchctl bootout system/\(label)"
        case .removeDaemon(let label, let plist):
            try Self.validateLabel(label)
            guard plist.deletingLastPathComponent().resolvingSymlinksInPath().path == "/Library/LaunchDaemons" else {
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

    static func validateLabel(_ label: String) throws {
        guard label.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw AdminError.refused("label non valida")
        }
    }

    /// Shell steps that act on one item from inside its folder.
    ///
    /// Paths are checked before the password prompt, and the prompt can stay
    /// open for a while. If a folder on the way were swapped for a symlink in
    /// the meantime, a full path would lead somewhere else. So the root shell
    /// enters the folder, checks that it is still the one validated, and then
    /// works on "./name": once inside, later swaps of the path no longer matter,
    /// and `rm` and `mv` never follow a symlink in the last component.
    static func insideFolder(of url: URL, _ action: (String) -> String) throws -> String {
        guard let parent = realPath(url.deletingLastPathComponent()) else {
            throw AdminError.refused("\(url.path): cartella non trovata")
        }
        let folder = shellQuote(parent)
        let item = shellQuote("./" + url.lastPathComponent)
        return "( cd -P -- \(folder) && [ \"$(pwd -P)\" = \(folder) ] "
            + "|| { echo \(shellQuote("cartella cambiata dopo il controllo: \(parent)")) >&2; exit 1; }; "
            + "\(action(item)) )"
    }

    /// The path with every symlink resolved, as the shell's `pwd -P` prints it
    /// (unlike `resolvingSymlinksInPath`, this keeps "/private").
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
        }
    }

    /// Where each item lands in the Trash: its own name, or "name 2", "name 3"…
    /// when that name is already taken (in the Trash or earlier in the batch).
    static func trashDestinations(_ urls: [URL], trash: URL) -> [(source: URL, destination: URL)] {
        var taken: Set<String> = []
        return urls.map { url in
            let ext = url.pathExtension
            let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            var name = url.lastPathComponent
            var counter = 2
            while taken.contains(name.lowercased())
                    || FileManager.default.fileExists(atPath: trash.appendingPathComponent(name).path) {
                name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
                counter += 1
            }
            taken.insert(name.lowercased())
            return (url, trash.appendingPathComponent(name))
        }
    }

    /// Asks for the password and runs the operation. Blocks until done.
    public func run(_ operation: AdminOperation) throws {
        let shell = try command(for: operation)
        let script = "do shell script \(Self.appleScriptString(shell)) with administrator privileges "
            + "with prompt \(Self.appleScriptString("MacCleaner: \(operation.title)"))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        log?.recordAdmin(operation.title, ok: process.terminationStatus == 0, detail: shell)
        guard process.terminationStatus == 0 else {
            if message.contains("-128") { throw AdminError.cancelled }
            throw AdminError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
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
