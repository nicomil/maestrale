import Foundation
import MaestraleCore

/// A text report of the Protection scan, to send to whoever helps from afar.
public enum ProtectionReport {
    public static func markdown(status: ProtectionStatus?, findings: [Finding], ignored: Set<String> = [],
                                activities: [ProcessActivity] = [], date: Date = Date(), host: String = Host.current().localizedName ?? "Mac") -> String {
        var lines: [String] = []
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        lines.append("# Rapporto Protezione · \(host)")
        lines.append("")
        lines.append("Generato da Maestrale il \(date.formatted(date: .long, time: .shortened)) · macOS \(version)")
        lines.append("")
        if let status {
            lines.append("## Difese di macOS")
            lines.append("")
            func state(_ value: Bool?) -> String { value == nil ? "sconosciuto" : value! ? "attivo" : "**DISATTIVATO**" }
            lines.append("- Gatekeeper: \(state(status.gatekeeperEnabled))")
            lines.append("- Protezione integrità (SIP): \(state(status.sipEnabled))")
            lines.append("- Firewall: \(state(status.firewallEnabled))")
            lines.append("- XProtect: \(status.xprotectVersion ?? "sconosciuto")")
            lines.append("")
        }
        let visible = findings.filter { !ignored.contains($0.id) }
        let counts = Dictionary(grouping: visible, by: \.severity).mapValues(\.count)
        lines.append("## Riepilogo")
        lines.append("")
        lines.append("- Pericoli: \(counts[.danger] ?? 0)")
        lines.append("- Avvisi: \(counts[.warning] ?? 0)")
        lines.append("- Informazioni: \(counts[.info] ?? 0)")
        lines.append("- Nuovi dall'ultimo controllo: \(visible.filter(\.isNew).count)")
        if !ignored.isEmpty { lines.append("- Ignorati dall'utente: \(findings.count - visible.count)") }
        lines.append("")
        for category in FindingCategory.allCases {
            let items = visible.filter { $0.category == category }
            guard !items.isEmpty else { continue }
            lines.append("## \(category.title)")
            lines.append("")
            for finding in items {
                let badge = finding.severity == .danger ? "PERICOLO" : finding.severity == .warning ? "Avviso" : "Info"
                lines.append("### \(badge)\(finding.isNew ? " · nuovo" : ""): \(finding.title)")
                lines.append("")
                for reason in finding.reasons { lines.append("- \(reason)") }
                if let path = finding.path { lines.append("- Percorso: `\(path.path)`") }
                if let team = finding.team { lines.append("- Team ID: \(team)") }
                if !finding.evidence.isEmpty {
                    lines.append("")
                    lines.append("```")
                    lines += finding.evidence
                    lines.append("```")
                }
                lines.append("")
            }
        }
        if !activities.isEmpty {
            lines.append("## Processi più attivi")
            lines.append("")
            lines.append("| Processo | PID | CPU | Memoria | Rete | Percorso |")
            lines.append("|---|---|---|---|---|---|")
            for activity in activities.sorted(by: { $0.cpu > $1.cpu }).prefix(15) {
                let memory = ByteCountFormatter.string(fromByteCount: Int64(activity.memory), countStyle: .memory)
                let network = ByteCountFormatter.string(fromByteCount: Int64(activity.networkInPerSecond + activity.networkOutPerSecond), countStyle: .file)
                lines.append("| \(activity.process.name) | \(activity.process.pid) | \(Int(activity.cpu * 100))% | \(memory) | \(network)/s | `\(activity.process.path ?? "")` |")
            }
            lines.append("")
        }
        lines.append("_Controlli euristici: un avviso non è una prova di malware._")
        return lines.joined(separator: "\n")
    }
}
