import Foundation
import MacCleanerCore

/// One record of `sfltool dumpbtm`: what Background Task Management knows
/// about a login item, agent or daemon.
public struct BackgroundItem: Equatable, Sendable {
    public var fields: [String: String] = [:]
    public var name: String { fields["Name"] ?? "?" }
    public var identifier: String { fields["Identifier"] ?? "" }
    public var type: String { fields["Type"]?.components(separatedBy: " (").first ?? "" }
    public var url: String? { fields["URL"].flatMap { $0 == "(null)" ? nil : $0 } }
    public var executable: String? { fields["Executable Path"].flatMap { $0 == "(null)" ? nil : $0 } }
    public var team: String? { fields["Team Identifier"].flatMap { $0 == "(null)" ? nil : $0 } }
    public var developer: String? { fields["Developer Name"].flatMap { $0 == "(null)" ? nil : $0 } }
    public var parent: String? { fields["Parent Identifier"] }
    /// "[enabled, allowed, …]": the user did not switch it off, and macOS lets it run.
    public var isEnabled: Bool {
        guard let disposition = fields["Disposition"] else { return false }
        return disposition.contains("enabled") && !disposition.contains("disabled") && !disposition.contains("disallowed")
    }

    /// Parses the text dump: records start with "#N:" and hold "Key: value" lines.
    public static func parse(_ text: String) -> [BackgroundItem] {
        var items: [BackgroundItem] = []
        var current: BackgroundItem?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.range(of: #"^#\d+:$"#, options: .regularExpression) != nil {
                if let current { items.append(current) }
                current = BackgroundItem()
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // "Embedded Item Identifiers:" opens a list, which is not a field.
            guard !key.isEmpty, !key.hasPrefix("#"), key != "Embedded Item Identifiers" else { continue }
            if current?.fields[key] == nil { current?.fields[key] = value }
        }
        if let current { items.append(current) }
        return items
    }
}

/// Login items and background items registered with macOS (the list in
/// System Settings → General → Login Items), checked like launch items.
/// Legacy agents and daemons are left to `LaunchItemsCheck`.
public struct LoginItemsCheck: ProtectionCheck {
    public let id = "login-items"
    public let title = "Elementi di login"

    public init() {}

    public func run(_ context: CheckContext) -> [Finding] {
        let items = BackgroundItem.parse(context.commands.run("/usr/bin/sfltool", ["dumpbtm"]))
        let byIdentifier = Dictionary(items.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        var findings: [Finding] = []
        for item in items where item.isEnabled {
            guard ["login item", "agent", "background tasks", "app"].contains(item.type) else { continue }
            guard let path = Self.executablePath(item, parents: byIdentifier) else { continue }
            var reasons: [String] = []
            var severity = Finding.Severity.info
            let signature = context.signatures.signature(of: URL(fileURLWithPath: path))
            if item.type != "app" || item.team == nil {
                let assessed = signature.assess(path: path)
                reasons += assessed.reasons
                severity = max(severity, assessed.severity)
            }
            switch KnownLocations.kind(of: path) {
            case .temporary:
                reasons.append("Avviato da una cartella temporanea o condivisa")
                severity = .danger
            case .hidden:
                reasons.append("Avviato da una cartella nascosta")
                severity = max(severity, .warning)
            case .normal:
                break
            }
            guard !reasons.isEmpty else { continue }
            findings.append(Finding(category: .persistence, key: "btm|\(item.identifier)", severity: severity,
                                    title: item.name, path: URL(fileURLWithPath: path), reasons: reasons,
                                    evidence: ["Tipo: \(item.type)", "Identificatore: \(item.identifier)",
                                               "Sviluppatore: \(item.developer ?? "sconosciuto") \(item.team.map { "(\($0))" } ?? "")",
                                               "Stato: \(item.fields["Disposition"] ?? "?")"],
                                    action: .openSettings(SettingsLinks.loginItems), team: signature.team))
        }
        return findings
    }

    /// The executable, or the bundle: a relative URL ("Contents/Library/LoginItems/X.app")
    /// is inside the parent app.
    static func executablePath(_ item: BackgroundItem, parents: [String: BackgroundItem]) -> String? {
        let parentURL = item.parent.flatMap { parents[$0]?.url }.flatMap { $0.hasPrefix("/") ? $0 : nil }
        func resolve(_ path: String) -> String? {
            if path.hasPrefix("/") { return path }
            return parentURL.map { $0 + "/" + path }
        }
        if let executable = item.executable, let resolved = resolve(executable) { return resolved }
        if let url = item.url, let resolved = resolve(url) { return resolved }
        return parentURL
    }
}
