import Foundation
import MaestraleCore

/// Programs started by launchd: signature, where they live, and labels that
/// pretend to be Apple's.
public struct LaunchItemsCheck: ProtectionCheck {
    public let id = "launch-items"
    public let title = "Elementi di avvio"

    public init() {}

    public func run(_ context: CheckContext) -> [Finding] {
        var findings: [Finding] = []
        for item in context.launchItems {
            guard let program = item.program, program.hasPrefix("/") else { continue }
            if item.isBroken { continue } // handled by System Junk as "broken"
            let signature = context.signatures.signature(of: URL(fileURLWithPath: program))
            var (reasons, severity) = signature.assess(path: program)
            var evidence = ["Label: \(item.label)", "Programma: \(program)", "Plist: \(item.plist.path)"]
            switch KnownLocations.kind(of: program) {
            case .temporary:
                reasons.append("Avviato da una cartella temporanea o condivisa")
                severity = .danger
            case .hidden:
                reasons.append("Avviato da una cartella nascosta")
                severity = max(severity, .warning)
            case .normal:
                break
            }
            if item.label.hasPrefix("com.apple.") && !KnownLocations.isSystem(program) {
                reasons.append("Si spaccia per un componente Apple")
                severity = .danger
            }
            if let plist = NSDictionary(contentsOf: item.plist) as? [String: Any],
               let env = plist["EnvironmentVariables"] as? [String: Any],
               let inserted = env["DYLD_INSERT_LIBRARIES"] as? String, !inserted.isEmpty {
                reasons.append("Inietta una libreria in altri programmi (DYLD_INSERT_LIBRARIES)")
                evidence.append("DYLD_INSERT_LIBRARIES = \(inserted)")
                severity = .danger
            }
            guard !reasons.isEmpty else { continue }
            findings.append(Finding(category: .persistence, key: item.plist.path, severity: severity, title: item.label,
                                    path: URL(fileURLWithPath: program), reasons: reasons, evidence: evidence,
                                    action: .removeLaunchItem, launchItem: item, team: signature.team))
        }
        return findings
    }
}
