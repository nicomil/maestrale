import Foundation
import MaestraleCore

/// Third-party system extensions and kernel extensions: they see all network
/// traffic or run inside the kernel, so the user should know they are there.
public struct SystemExtensionsCheck: ProtectionCheck {
    public let id = "system-extensions"
    public let title = "Estensioni di sistema e kernel"

    public init() {}

    public func run(_ context: CheckContext) -> [Finding] {
        var findings: [Finding] = []
        for extensionInfo in Self.parseSystemExtensions(context.commands.run("/usr/bin/systemextensionsctl", ["list"])) {
            guard extensionInfo.enabled else { continue }
            let kind = extensionInfo.category.contains("network") ? "Estensione di rete" : extensionInfo.category.contains("endpoint") ? "Estensione di sicurezza" : "Estensione di sistema"
            findings.append(Finding(category: .configuration, key: "sysext|\(extensionInfo.bundleID)", severity: .info,
                                    title: "\(kind): \(extensionInfo.name)",
                                    reasons: [extensionInfo.category.contains("network") ? "Vede o filtra tutto il traffico di rete del Mac" : "Gira con privilegi di sistema"],
                                    evidence: ["Bundle: \(extensionInfo.bundleID)", "Team: \(extensionInfo.team)", "Stato: \(extensionInfo.state)"],
                                    action: .openSettings(SettingsLinks.loginItems), team: extensionInfo.team))
        }
        for kext in Self.parseKexts(context.commands.run("/usr/bin/kmutil", ["showloaded", "--list-only"])) {
            findings.append(Finding(category: .configuration, key: "kext|\(kext)", severity: .warning,
                                    title: "Estensione del kernel: \(kext)",
                                    reasons: ["Codice di terzi caricato nel kernel: può fare qualsiasi cosa e rende il Mac instabile"],
                                    action: .openSettings(SettingsLinks.loginItems)))
        }
        return findings
    }

    public struct SystemExtension: Equatable, Sendable {
        public let enabled: Bool
        public let team: String
        public let bundleID: String
        public let name: String
        public let state: String
        public let category: String
    }

    /// `systemextensionsctl list`: "--- category" headers, then tab-separated
    /// rows "enabled active teamID bundleID (version) name [state]".
    static func parseSystemExtensions(_ text: String) -> [SystemExtension] {
        var result: [SystemExtension] = []
        var category = ""
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("--- ") { category = line; continue }
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 5, fields[0] != "enabled" else { continue }
            let bundle = fields[3].components(separatedBy: " (").first ?? fields[3]
            result.append(SystemExtension(enabled: fields[0].contains("*"), team: fields[2], bundleID: bundle, name: fields[4],
                                          state: fields.count > 5 ? fields[5] : "", category: category))
        }
        return result
    }

    /// Non-Apple bundle identifiers in `kmutil showloaded --list-only`.
    static func parseKexts(_ text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line -> String? in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 6, Int(columns[0]) != nil else { return nil }
            let name = String(columns[5])
            return name.hasPrefix("com.apple.") ? nil : name
        }
    }
}
