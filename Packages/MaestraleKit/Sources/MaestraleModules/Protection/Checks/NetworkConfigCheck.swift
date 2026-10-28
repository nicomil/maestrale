import Foundation
import MaestraleCore

/// Where the Mac's traffic goes: /etc/hosts, proxies, DNS servers and
/// libraries injected into every process.
public struct NetworkConfigCheck: ProtectionCheck {
    public let id = "network-config"
    public let title = "Configurazione di rete"
    let hostsFile: URL

    public init(hostsFile: URL = URL(fileURLWithPath: "/etc/hosts")) {
        self.hostsFile = hostsFile
    }

    static let knownResolvers: Set<String> = ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112",
                                              "208.67.222.222", "208.67.220.220", "94.140.14.14", "94.140.15.15",
                                              "2606:4700:4700::1111", "2606:4700:4700::1001", "2001:4860:4860::8888", "2001:4860:4860::8844"]

    public func run(_ context: CheckContext) -> [Finding] {
        var findings: [Finding] = []

        if let hosts = context.text(of: hostsFile) {
            let entries = Self.hostsEntries(hosts)
            let redirects = entries.filter { !$0.isLoopback }
            let blocks = entries.filter(\.isLoopback)
            if !redirects.isEmpty {
                // A real domain pointed elsewhere is a hijack; made-up names
                // (".vibe", ".test") are a developer's local setup.
                let real = redirects.filter { $0.names.contains(where: Self.looksPublic) }
                findings.append(Finding(category: .network, key: "hosts-redirect", severity: real.isEmpty ? .warning : .danger,
                                        title: "/etc/hosts manda \(redirects.count) nomi verso altri indirizzi", path: hostsFile,
                                        reasons: [real.isEmpty ? "Nomi locali o di prova risolti a mano: normale per chi sviluppa, da controllare altrimenti"
                                                  : "Domini veri risolti su indirizzi scelti da qualcuno: possono dirottare siti e aggiornamenti"],
                                        evidence: redirects.prefix(30).map(\.line)))
            }
            if !blocks.isEmpty {
                findings.append(Finding(category: .network, key: "hosts-block", severity: .info,
                                        title: "/etc/hosts blocca \(blocks.count) nomi", path: hostsFile,
                                        reasons: ["Voci che puntano a localhost: tipiche di blocchi pubblicità o di test, ma anche di malware che blocca gli antivirus"],
                                        evidence: blocks.prefix(30).map(\.line)))
            }
        }

        let services = context.commands.run("/usr/sbin/networksetup", ["-listallnetworkservices"])
            .components(separatedBy: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
        for service in services {
            for (flag, kind) in [("-getwebproxy", "HTTP"), ("-getsecurewebproxy", "HTTPS"), ("-getsocksfirewallproxy", "SOCKS")] {
                let output = context.commands.run("/usr/sbin/networksetup", [flag, service])
                guard output.contains("Enabled: Yes"), let server = Self.value("Server", in: output), !server.isEmpty else { continue }
                findings.append(Finding(category: .network, key: "proxy|\(service)|\(kind)", severity: .danger,
                                        title: "Proxy \(kind) su \(service)",
                                        reasons: ["Tutto il traffico \(kind) passa da \(server): chi lo controlla vede e modifica quello che fai"],
                                        evidence: output.components(separatedBy: "\n").filter { !$0.isEmpty },
                                        action: .openSettings("x-apple.systempreferences:com.apple.Network-Settings.extension")))
            }
            let auto = context.commands.run("/usr/sbin/networksetup", ["-getautoproxyurl", service])
            if auto.contains("Enabled: Yes"), let url = Self.value("URL", in: auto), url != "(null)" {
                findings.append(Finding(category: .network, key: "pac|\(service)", severity: .danger,
                                        title: "Configurazione proxy automatica su \(service)",
                                        reasons: ["Uno script remoto (PAC) decide da dove passa il traffico: \(url)"],
                                        evidence: auto.components(separatedBy: "\n").filter { !$0.isEmpty },
                                        action: .openSettings("x-apple.systempreferences:com.apple.Network-Settings.extension")))
            }
        }

        let dns = context.commands.run("/usr/sbin/scutil", ["--dns"])
        let servers = Self.nameservers(dns)
        let odd = servers.filter { !Self.knownResolvers.contains($0) && !Self.isPrivate($0) }
        if !odd.isEmpty {
            findings.append(Finding(category: .network, key: "dns", severity: .warning,
                                    title: "Server DNS insoliti: \(odd.joined(separator: ", "))",
                                    reasons: ["Non sono né il router né un servizio DNS conosciuto: possono mandare i siti dove vogliono"],
                                    evidence: servers.map { "nameserver: \($0)" },
                                    action: .openSettings("x-apple.systempreferences:com.apple.Network-Settings.extension")))
        }

        let inserted = context.commands.run("/bin/launchctl", ["getenv", "DYLD_INSERT_LIBRARIES"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !inserted.isEmpty {
            findings.append(Finding(category: .configuration, key: "dyld-insert", severity: .danger,
                                    title: "Libreria iniettata in tutti i programmi",
                                    path: URL(fileURLWithPath: inserted.components(separatedBy: ":").first ?? inserted),
                                    reasons: ["DYLD_INSERT_LIBRARIES è impostata per l'intera sessione: ogni app carica questo codice"],
                                    evidence: ["DYLD_INSERT_LIBRARIES = \(inserted)"]))
        }
        return findings
    }

    public struct HostsEntry: Equatable, Sendable {
        public let address: String
        public let names: [String]
        public let line: String
        public var isLoopback: Bool { address == "127.0.0.1" || address == "::1" || address == "0.0.0.0" || address.hasPrefix("127.") || address == "fe80::1%lo0" }
    }

    /// Lines of /etc/hosts except comments and the entries every Mac has.
    static func hostsEntries(_ text: String) -> [HostsEntry] {
        text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.components(separatedBy: "#").first?.trimmingCharacters(in: .whitespaces) ?? ""
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { return nil }
            let names = Array(parts.dropFirst())
            let standard: Set<String> = ["localhost", "broadcasthost", "localhost.localdomain"]
            if names.allSatisfy({ standard.contains($0) }) { return nil }
            return HostsEntry(address: parts[0], names: names, line: line)
        }
    }

    static let publicSuffixes: Set<String> = ["com", "net", "org", "it", "eu", "de", "fr", "es", "uk", "io", "co", "app", "me", "info",
                                              "biz", "tv", "ch", "at", "nl", "be", "us", "ca", "au", "edu", "gov", "cloud", "ai", "xyz"]

    static func looksPublic(_ name: String) -> Bool {
        guard let suffix = name.split(separator: ".").last, name.contains(".") else { return false }
        return publicSuffixes.contains(suffix.lowercased())
    }

    static func value(_ key: String, in text: String) -> String? {
        text.components(separatedBy: "\n").first { $0.hasPrefix("\(key):") }
            .map { $0.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces) }
    }

    static func nameservers(_ scutil: String) -> [String] {
        var seen: [String] = []
        for line in scutil.components(separatedBy: "\n") {
            guard let match = line.firstMatch(of: /nameserver\[\d+\]\s*:\s*(\S+)/) else { continue }
            let server = String(match.1)
            if !seen.contains(server) { seen.append(server) }
        }
        return seen
    }

    static func isPrivate(_ address: String) -> Bool {
        address.hasPrefix("10.") || address.hasPrefix("192.168.") || address.hasPrefix("127.") || address.hasPrefix("fe80:")
            || address.hasPrefix("fd") || address.hasPrefix("fc") || address.hasPrefix("169.254.")
            || (address.hasPrefix("172.") && (16...31).contains(Int(address.split(separator: ".").dropFirst().first ?? "") ?? 0))
            || address.contains("%")
    }
}
