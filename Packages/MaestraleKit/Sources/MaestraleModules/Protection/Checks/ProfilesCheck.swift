import Foundation
import MaestraleCore

/// Configuration profiles: a private Mac should have none. Adware installs
/// them to force a search engine, a DNS server or a proxy, and to add a
/// root certificate for intercepting HTTPS.
public struct ProfilesCheck: ProtectionCheck {
    public let id = "profiles"
    public let title = "Profili di configurazione"

    public init() {}

    static let dangerousPayloads: [String: String] = [
        "com.apple.dnsSettings.managed": "Cambia i server DNS",
        "com.apple.dnsProxy.managed": "Instrada il DNS attraverso un proxy",
        "com.apple.webcontent-filter": "Filtra o intercetta il traffico web",
        "com.apple.proxy.http.global": "Imposta un proxy per tutto il traffico",
        "com.apple.security.root": "Installa un certificato radice (può intercettare HTTPS)",
        "com.apple.security.pem": "Installa un certificato",
        "com.apple.security.pkcs1": "Installa un certificato",
        "com.apple.security.pkcs12": "Installa un certificato con chiave privata",
        "com.apple.ManagedClient.preferences": "Forza impostazioni di app (es. motore di ricerca del browser)",
        "com.apple.applicationaccess": "Limita quello che puoi fare sul Mac",
        "com.apple.mdm": "Gestione remota del Mac (MDM)",
        "com.apple.vpn.managed": "Configura una VPN",
        "com.apple.system-extension-policy": "Autorizza estensioni di sistema",
        "com.apple.TCC.configuration-profile-policy": "Concede permessi di privacy alle app",
    ]

    public func run(_ context: CheckContext) -> [Finding] {
        var findings: [Finding] = []
        let user = context.commands.run("/usr/bin/profiles", ["list", "-output", "stdout-xml"])
        findings += Self.findings(in: user, scope: "utente")
        if let system = context.systemEvidence?["profiles"] {
            findings += Self.findings(in: system, scope: "sistema")
        }
        return findings
    }

    /// `profiles … -output stdout-xml` prints a plist: a dictionary of scopes,
    /// each an array of profiles with ProfileItems (payloads).
    static func findings(in text: String, scope: String) -> [Finding] {
        guard let start = text.range(of: "<?xml"), let data = String(text[start.lowerBound...]).data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var findings: [Finding] = []
        for case let (_, profiles as [[String: Any]]) in root {
            for profile in profiles {
                let name = profile["ProfileDisplayName"] as? String ?? profile["ProfileIdentifier"] as? String ?? "Profilo"
                let identifier = profile["ProfileIdentifier"] as? String ?? name
                let items = profile["ProfileItems"] as? [[String: Any]] ?? []
                let payloads = items.compactMap { $0["PayloadType"] as? String }
                var reasons: [String] = []
                for payload in payloads {
                    if let reason = dangerousPayloads[payload], !reasons.contains(reason) { reasons.append(reason) }
                }
                let severity: Finding.Severity = reasons.isEmpty ? .warning : .danger
                if reasons.isEmpty { reasons = ["Un Mac personale non dovrebbe avere profili: rimuovilo se non sai chi l'ha installato"] }
                var evidence = ["Identificatore: \(identifier)", "Ambito: \(scope)"] + payloads.map { "Payload: \($0)" }
                if let organization = profile["ProfileOrganization"] as? String { evidence.append("Organizzazione: \(organization)") }
                if let date = profile["ProfileInstallDate"] as? String { evidence.append("Installato: \(date)") }
                findings.append(Finding(category: .configuration, key: "profile|\(scope)|\(identifier)", severity: severity,
                                        title: "Profilo: \(name)", reasons: reasons, evidence: evidence,
                                        action: .openSettings(SettingsLinks.profiles)))
            }
        }
        return findings
    }
}
