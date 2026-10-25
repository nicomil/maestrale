import Foundation
import MacCleanerCore

/// Operations that need administrator rights. The set is closed on purpose:
/// nothing outside this enum can be run as root by the app.
public enum AdminOperation: Sendable, Equatable {
    /// Remove files under the system folders listed in `AdminRunner.systemRoots`.
    case remove([URL])
    case freeRAM
    case flushDNS
    case reindexSpotlight
    case repairPermissions
    case runPeriodicScripts
    case thinLocalSnapshots
    case removeWiFiNetwork(String)
    case bootoutDaemon(label: String)

    public var title: String {
        switch self {
        case .remove(let urls): "Rimozione di \(urls.count) elementi di sistema"
        case .freeRAM: "Liberare la RAM"
        case .flushDNS: "Svuotare la cache DNS"
        case .reindexSpotlight: "Reindicizzare Spotlight"
        case .repairPermissions: "Riparare i permessi della cartella Inizio"
        case .runPeriodicScripts: "Eseguire gli script di manutenzione"
        case .thinLocalSnapshots: "Liberare lo spazio eliminabile"
        case .removeWiFiNetwork(let name): "Dimenticare la rete \(name)"
        case .bootoutDaemon(let label): "Fermare \(label)"
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
    public func command(for operation: AdminOperation, uid: uid_t = getuid()) throws -> String {
        switch operation {
        case .remove(let urls):
            guard !urls.isEmpty else { throw AdminError.refused("nessun elemento") }
            let validator = SafeRemover(allowedRoots: Self.systemRoots, mode: .dryRun, log: nil)
            for url in urls {
                if let error = validator.validate(url) { throw AdminError.refused("\(url.path): \(error)") }
            }
            return "/bin/rm -rf -- " + urls.map { Self.shellQuote($0.path) }.joined(separator: " ")
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
            guard label.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
                throw AdminError.refused("label non valida")
            }
            return "/bin/launchctl bootout system/\(label)"
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
