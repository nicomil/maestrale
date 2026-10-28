import Foundation
import MaestraleCore

/// Apple's own antimalware: how fresh its definitions are and what XProtect
/// Remediator found in the last week.
public struct XProtectCheck: ProtectionCheck {
    public let id = "xprotect"
    public let title = "XProtect"
    let bundleInfo: URL
    let staleAfterDays: Int

    public init(bundleInfo: URL = URL(fileURLWithPath: "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"),
                staleAfterDays: Int = 30) {
        self.bundleInfo = bundleInfo
        self.staleAfterDays = staleAfterDays
    }

    public struct Definitions: Equatable, Sendable {
        public var version: String?
        public var installed: Date?
    }

    public func run(_ context: CheckContext) -> [Finding] {
        var findings: [Finding] = []
        let definitions = Self.definitions(context: context, bundleInfo: bundleInfo)
        if let installed = definitions.installed {
            let days = Int(context.now.timeIntervalSince(installed) / 86_400)
            if days > staleAfterDays {
                findings.append(Finding(category: .defense, key: "xprotect-stale", severity: .warning,
                                        title: "Definizioni XProtect vecchie di \(days) giorni",
                                        reasons: ["Apple le aggiorna più volte al mese: il Mac non le sta ricevendo"],
                                        evidence: ["Versione \(definitions.version ?? "?") installata il \(installed.formatted(date: .numeric, time: .omitted))"],
                                        action: .updateXProtect))
            }
        } else if definitions.version == nil {
            findings.append(Finding(category: .defense, key: "xprotect-missing", severity: .danger,
                                    title: "XProtect non trovato",
                                    reasons: ["Le definizioni antimalware di Apple mancano o non sono leggibili"],
                                    action: .updateXProtect))
        }

        let log = context.commands.run("/usr/bin/log", ["show", "--last", "7d", "--style", "compact", "--predicate",
                                                        "subsystem == \"com.apple.XProtectFramework.PluginAPI\""])
        let (runs, detections) = Self.parseRemediatorLog(log)
        for detection in detections {
            findings.append(Finding(category: .defense, key: "xprotect-detection|\(detection.module)|\(detection.subject ?? "")",
                                    severity: .danger, title: "XProtect Remediator ha trovato qualcosa: \(detection.module)",
                                    path: detection.subject.map { URL(fileURLWithPath: $0) },
                                    reasons: ["Negli ultimi 7 giorni Apple ha rilevato o rimosso un malware noto"],
                                    evidence: [detection.line]))
        }
        if !log.isEmpty, runs == 0, !log.contains("log: ") {
            findings.append(Finding(category: .defense, key: "xprotect-remediator-idle", severity: .info,
                                    title: "XProtect Remediator non ha girato negli ultimi 7 giorni",
                                    reasons: ["Gira da solo quando il Mac è acceso e inattivo: lascialo acceso qualche ora"]))
        }
        return findings
    }

    /// Version and install date from `xprotect version` (macOS 15+), or from
    /// the bundle's Info.plist and its modification date.
    static func definitions(context: CheckContext, bundleInfo: URL) -> Definitions {
        var result = Definitions()
        let output = context.commands.run("/usr/bin/xprotect", ["version"])
        if let match = output.firstMatch(of: /Version:\s*(\S+)\s+Installed:\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4})/) {
            result.version = String(match.1)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            result.installed = formatter.date(from: String(match.2))
        }
        if result.version == nil, let info = NSDictionary(contentsOf: bundleInfo) as? [String: Any] {
            result.version = info["CFBundleShortVersionString"] as? String
            result.installed = (try? bundleInfo.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        return result
    }

    public struct Detection: Equatable, Sendable {
        public let module: String
        public let subject: String?
        public let line: String
    }

    /// Every line comes from one of the XProtectRemediator* processes, so any
    /// line proves that module ran. Where macOS still logs the structured
    /// "XPEvent.structured" JSON, a non-zero status_code or a subject is a
    /// detection or a remediation.
    static func parseRemediatorLog(_ text: String) -> (runs: Int, detections: [Detection]) {
        var modules: Set<String> = []
        var detections: [Detection] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let processModule = line.firstMatch(of: /XProtectRemediator(\w+)\[/).map { String($0.1) }
            if let processModule { modules.insert(processModule) }
            guard let start = line.firstIndex(of: "{"), line.contains("XPEvent") || line.contains("status_code") else { continue }
            let json = String(line[start...])
            guard let data = json.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // The module is in the JSON on some systems and only in the process name on others.
            let module = (event["module"] as? String ?? event["process_name"] as? String ?? processModule ?? "?")
                .replacingOccurrences(of: "XProtectRemediator", with: "")
            let subject = event["subject"] as? String
            let message = (event["status_message"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            // status_code is not a verdict (20 goes with "NoThreatDetected"): trust the message and the subject.
            let negative = message.contains("nothreat") || message.contains("notdetected") || message.contains("nothing")
            let detected = (subject?.isEmpty == false) || (!negative && (message.contains("detect") || message.contains("remediat")))
            if detected {
                detections.append(Detection(module: module, subject: subject?.isEmpty == false ? subject : nil, line: json))
            }
        }
        return (modules.count, detections)
    }
}
