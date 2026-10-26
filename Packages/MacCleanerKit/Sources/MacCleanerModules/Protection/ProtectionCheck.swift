import Foundation
import MacCleanerCore

/// Where a finding comes from. Drives the grouping of the Protection screen.
public enum FindingCategory: String, CaseIterable, Sendable, Codable {
    case persistence, application, browser, process, network, configuration, defense, signature

    public var title: String {
        switch self {
        case .persistence: "Avvio automatico"
        case .application: "Applicazioni"
        case .browser: "Browser"
        case .process: "Processi"
        case .network: "Rete"
        case .configuration: "Configurazione"
        case .defense: "Difese di macOS"
        case .signature: "Firme conosciute"
        }
    }
}

/// What the app suggests doing about a finding. Nothing happens without the user.
public enum FindingAction: Sendable, Hashable {
    case none
    /// Stop the launch item and move its plist to the Trash.
    case removeLaunchItem
    /// Move the file to the Trash (with the password when it is a system file).
    case trash
    /// Move the file into the app's quarantine folder.
    case quarantine
    /// Open a pane of System Settings (an `x-apple.systempreferences:` URL).
    case openSettings(String)
    /// Terminate the process (user processes only).
    case terminateProcess(pid: Int32)
    /// Ask macOS for new XProtect definitions (with the password).
    case updateXProtect
}

/// Something that deserves a look. Never removed automatically.
public struct Finding: Identifiable, Sendable, Hashable {
    public enum Severity: Int, Sendable, Comparable, Codable {
        case info, warning, danger
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .info: "Informazione"
            case .warning: "Avviso"
            case .danger: "Pericolo"
            }
        }
    }

    /// Stable across scans: the category plus a key chosen by the check
    /// (usually the path, or the setting's name).
    public let id: String
    public let category: FindingCategory
    public let severity: Severity
    public let title: String
    public let path: URL?
    /// Why it is listed, one short sentence each.
    public let reasons: [String]
    /// The raw lines the reasons are based on: a plist key, a line of a
    /// script, a permission. Shown on request.
    public let evidence: [String]
    public let action: FindingAction
    /// The launch item that starts it, if any (to disable before removing).
    public let launchItem: LaunchItem?
    /// The Team ID of the signer, when the finding is about a signed program.
    public let team: String?
    /// When this finding first appeared, according to the saved baseline.
    public var firstSeen: Date?
    /// True when the finding was not in the previous scan.
    public var isNew = false

    public init(category: FindingCategory, key: String, severity: Severity, title: String, path: URL? = nil,
                reasons: [String], evidence: [String] = [], action: FindingAction = .none,
                launchItem: LaunchItem? = nil, team: String? = nil) {
        self.id = "\(category.rawValue)|\(key)"
        self.category = category
        self.severity = severity
        self.title = title
        self.path = path
        self.reasons = reasons
        self.evidence = evidence
        self.action = action
        self.launchItem = launchItem
        self.team = team
    }
}

/// Kept for the code written against M5.
public typealias MalwareFinding = Finding

/// What a check needs before it can see anything.
public enum CheckRequirement: Sendable, Equatable {
    case none
    case fullDiskAccess
    /// Needs root: the check reads the output of `AdminOperation.collectSystemEvidence`.
    case admin
}

/// Runs external tools. Injected so tests can feed canned output to the parsers.
public protocol CommandRunner: Sendable {
    /// Standard output of the tool, or "" when it cannot run.
    func run(_ tool: String, _ arguments: [String]) -> String
}

/// Runs the real tool, with standard error folded into the output.
public struct SystemCommands: CommandRunner {
    public init() {}

    public func run(_ tool: String, _ arguments: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Canned output for tests: keyed by "tool arg1 arg2".
public struct FakeCommands: CommandRunner {
    public var outputs: [String: String]

    public init(_ outputs: [String: String] = [:]) { self.outputs = outputs }

    public func run(_ tool: String, _ arguments: [String]) -> String {
        outputs[([tool] + arguments).joined(separator: " ")] ?? ""
    }
}

/// Everything a check may need, built once per scan.
public struct CheckContext: Sendable {
    public let home: URL
    public let signatures: any CodeSignatureEvaluator
    public let commands: any CommandRunner
    public let now: Date
    /// The launch agents and daemons, read once and shared by the checks.
    public let launchItems: [LaunchItem]
    /// Output of the privileged, read-only evidence collection, when the user ran it.
    public let systemEvidence: SystemEvidence?
    /// Team IDs the user marked as trusted: signature findings about them are dropped.
    public let trustedTeams: Set<String>

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                signatures: any CodeSignatureEvaluator = CachedSignatures(),
                commands: any CommandRunner = SystemCommands(),
                now: Date = Date(),
                launchItems: [LaunchItem]? = nil,
                systemEvidence: SystemEvidence? = nil,
                trustedTeams: Set<String> = []) {
        self.home = home
        self.signatures = signatures
        self.commands = commands
        self.now = now
        self.launchItems = launchItems ?? LaunchItemsScanner(home: home).scan()
        self.systemEvidence = systemEvidence
        self.trustedTeams = trustedTeams
    }

    /// Reads a text file of at most `limit` bytes; nil when missing, unreadable or larger.
    public func text(of url: URL, limit: Int = 1_000_000) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= limit,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

/// Output of the one privileged, read-only command, split by section.
public struct SystemEvidence: Sendable, Equatable {
    public let sections: [String: String]
    public init(sections: [String: String]) { self.sections = sections }
}

/// One unit of the Protection scan.
public protocol ProtectionCheck: Sendable {
    var id: String { get }
    var title: String { get }
    var requirement: CheckRequirement { get }
    func run(_ context: CheckContext) -> [Finding]
}

extension ProtectionCheck {
    public var requirement: CheckRequirement { .none }
}

/// Where known programs live. Shared by several checks.
public enum KnownLocations {
    public static let packageManagers = ["/opt/homebrew/", "/usr/local/", "/opt/local/", "/nix/"]

    public enum Kind { case normal, hidden, temporary }

    /// Temporary and shared folders are where droppers put their payload;
    /// hidden folders outside app bundles are a classic hiding place.
    public static func kind(of path: String) -> Kind {
        let lower = path.lowercased()
        if lower.hasPrefix("/tmp/") || lower.hasPrefix("/private/tmp/") || lower.hasPrefix("/users/shared/")
            || lower.hasPrefix("/private/var/tmp/") || lower.hasPrefix("/var/tmp/") { return .temporary }
        let components = path.split(separator: "/")
        let hidden = components.dropLast().contains { $0.hasPrefix(".") && $0.count > 1 } && !lower.contains(".app/")
        return hidden ? .hidden : .normal
    }

    /// Hidden folders where developer tool chains keep their binaries.
    public static let developerFolders = ["/.local/", "/.pyenv/", "/.nvm/", "/.cargo/", "/.rustup/", "/.npm/", "/.bun/", "/.deno/",
                                          "/.rbenv/", "/.sdkman/", "/.cache/", "/.vscode/", "/.cursor/", "/.claude/", "/.codex/",
                                          "/.gem/", "/.go/", "/.volta/", "/.asdf/", "/.mise/", "/.ollama/", "/.docker/", "/.orbstack/",
                                          "/.rd/", "/.lima/", "/.colima/", "/.conda/", "/.pixi/", "/.uv/", "/.swiftpm/", "/.gradle/", "/.m2/"]

    public static func isDeveloperTooling(_ path: String) -> Bool {
        developerFolders.contains { path.contains($0) }
    }

    public static func isFromPackageManager(_ path: String) -> Bool {
        packageManagers.contains { path.hasPrefix($0) }
    }

    public static func isSystem(_ path: String) -> Bool {
        path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/")
            || path.hasPrefix("/Library/Apple/")
    }
}
