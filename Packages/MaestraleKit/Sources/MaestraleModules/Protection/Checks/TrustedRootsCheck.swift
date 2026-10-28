import Foundation
import MaestraleCore

/// Certificates the user or an administrator told macOS to trust. One
/// non-Apple root here lets whoever holds its key read HTTPS traffic.
public struct TrustedRootsCheck: ProtectionCheck {
    public let id = "trusted-roots"
    public let title = "Certificati fidati"

    public init() {}

    public func run(_ context: CheckContext) -> [Finding] {
        var findings: [Finding] = []
        for (arguments, scope) in [(["dump-trust-settings", "-d"], "amministratore"), (["dump-trust-settings"], "utente")] {
            let output = context.commands.run("/usr/bin/security", arguments)
            for cert in Self.parse(output) {
                let severity: Finding.Severity = cert.trusted ? .danger : .info
                findings.append(Finding(category: .configuration, key: "trust|\(scope)|\(cert.name)", severity: severity,
                                        title: "Certificato fidato: \(cert.name)",
                                        reasons: cert.trusted
                                            ? ["Un certificato aggiunto a mano è considerato attendibile: chi ha la sua chiave può intercettare le connessioni sicure"]
                                            : ["Certificato con impostazioni di fiducia personalizzate"],
                                        evidence: ["Ambito: \(scope)"] + cert.lines))
            }
        }
        return findings
    }

    public struct TrustedCert: Equatable, Sendable {
        public let name: String
        public let trusted: Bool
        public let lines: [String]
    }

    /// Output of `security dump-trust-settings`: "Cert N: name" blocks with
    /// "Result Type : kSecTrustResultProceed/Unspecified/Deny" lines.
    static func parse(_ text: String) -> [TrustedCert] {
        var certs: [TrustedCert] = []
        var name: String?
        var lines: [String] = []
        var deny = false
        var anyResult = false
        func flush() {
            if let name { certs.append(TrustedCert(name: name, trusted: !deny, lines: lines)) }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let match = line.firstMatch(of: /^Cert \d+: (.+)$/) {
                flush()
                name = String(match.1); lines = []; deny = false; anyResult = false
                continue
            }
            guard name != nil, !line.isEmpty else { continue }
            if line.contains("Result Type") {
                anyResult = true
                if line.contains("Deny") { deny = true }
            }
            lines.append(line)
        }
        flush()
        _ = anyResult
        return certs
    }
}
