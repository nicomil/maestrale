import Foundation
import MacCleanerCore

/// Cron jobs and the shell's start-up files: the oldest persistence trick,
/// still used by droppers (`curl … | sh` in ~/.zshrc).
public struct CronAndShellCheck: ProtectionCheck {
    public let id = "cron-shell"
    public let title = "Cron e file di avvio della shell"
    let systemFiles: [URL]
    let recentDays: Int

    public init(systemFiles: [URL]? = nil, recentDays: Int = 30) {
        self.systemFiles = systemFiles ?? ["/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/profile", "/etc/bashrc"].map { URL(fileURLWithPath: $0) }
        self.recentDays = recentDays
    }

    /// Patterns that have no business in a start-up file. The first group is
    /// a sure sign of a dropper; the second needs a look.
    static let dangerous: [(pattern: String, reason: String, severity: Finding.Severity)] = [
        (#"curl[^|\n]*\|\s*(sudo\s+)?(ba|z)?sh"#, "Scarica ed esegue codice dalla rete", .danger),
        (#"wget[^|\n]*\|\s*(sudo\s+)?(ba|z)?sh"#, "Scarica ed esegue codice dalla rete", .danger),
        (#"base64\s+(-d|--decode|-D)"#, "Decodifica codice nascosto in base64", .danger),
        (#"openssl\s+enc\s+-d"#, "Decifra codice nascosto", .danger),
        (#"(/tmp/|/private/tmp/|/Users/Shared/|/var/tmp/)\S+"#, "Esegue qualcosa da una cartella temporanea o condivisa", .danger),
        (#"\beval\s+["$(]"#, "Esegue codice costruito al volo (eval)", .warning),
        (#"(^|[\s;&|])nohup\s"#, "Avvia un processo che sopravvive alla chiusura del terminale", .warning),
        (#"osascript\s+-e"#, "Esegue AppleScript nascosto", .warning),
        (#"python[23]?\s+-c\s"#, "Esegue codice Python inline", .warning),
    ]

    /// `eval "$(brew shellenv)"` and friends: the normal way developer tools hook into the shell.
    static let knownEvalTools = ["brew shellenv", "pyenv init", "rbenv init", "nodenv init", "jenv init", "direnv hook", "starship init",
                                 "zoxide init", "fnm env", "conda shell", "mise activate", "mise env", "ssh-agent", "thefuck", "atuin init",
                                 "oh-my-posh", "goenv init", "luarocks path", "opam env", "swiftenv init", "asdf", "rustup", "gh completion",
                                 "docker completion", "kubectl completion", "helm completion", "pipenv --completion", "register-python-argcomplete",
                                 "keychain", "dircolors", "nvm", "sdkman", "cargo env", "ghcup", "autojump", "fasd", "rvm"]

    static func matches(_ line: String) -> [(reason: String, severity: Finding.Severity)] {
        var result: [(String, Finding.Severity)] = []
        for (pattern, reason, severity) in dangerous where line.range(of: pattern, options: .regularExpression) != nil {
            if reason.contains("eval"), knownEvalTools.contains(where: { line.contains($0) }) { continue }
            result.append((reason, severity))
        }
        return result
    }

    public func run(_ context: CheckContext) -> [Finding] {
        var findings: [Finding] = []
        let userFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile", ".bashrc", ".profile", ".bash_login"]
            .map { context.home.appendingPathComponent($0) }
        for file in userFiles + systemFiles {
            guard let text = context.text(of: file, limit: 2_000_000) else { continue }
            findings += Self.inspect(text, title: file.lastPathComponent, key: file.path, path: file,
                                     modified: (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                                     context: context, recentDays: recentDays)
        }

        let crontab = context.commands.run("/usr/bin/crontab", ["-l"])
        if !crontab.isEmpty, !crontab.contains("no crontab for") {
            findings += Self.cronFindings(crontab, owner: NSUserName(), key: "crontab", context: context)
        }
        if let section = context.systemEvidence?["crontabs"] {
            var owner = "root"
            var lines: [String] = []
            func flush() { if !lines.isEmpty { findings += Self.cronFindings(lines.joined(separator: "\n"), owner: owner, key: "crontab|\(owner)", context: context) } }
            for line in section.components(separatedBy: "\n") {
                if line.hasPrefix("## ") { flush(); owner = String(line.dropFirst(3)).components(separatedBy: "/").last ?? "root"; lines = [] }
                else { lines.append(line) }
            }
            flush()
        }
        if let sudoers = context.systemEvidence?["sudoers"], !sudoers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = sudoers.components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
            if lines.contains(where: { $0.contains("NOPASSWD") }) {
                findings.append(Finding(category: .configuration, key: "sudoers-nopasswd", severity: .warning,
                                        title: "Comandi root senza password (sudoers.d)",
                                        path: URL(fileURLWithPath: "/etc/sudoers.d"),
                                        reasons: ["Un file in /etc/sudoers.d permette sudo senza password"],
                                        evidence: lines.filter { $0.contains("NOPASSWD") }))
            }
        }
        return findings
    }

    static func cronFindings(_ text: String, owner: String, key: String, context: CheckContext) -> [Finding] {
        var findings: [Finding] = []
        let jobs = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
        guard !jobs.isEmpty else { return [] }
        var reasons: [String] = []
        var severity = Finding.Severity.info
        for job in jobs {
            for (reason, found) in matches(job) {
                if !reasons.contains(reason) { reasons.append(reason) }
                severity = max(severity, found)
            }
        }
        if reasons.isEmpty { reasons = ["\(jobs.count) operazioni pianificate con cron: controlla che siano tue"] }
        findings.append(Finding(category: .persistence, key: key, severity: severity,
                                title: "Cron di \(owner)", reasons: reasons, evidence: jobs))
        return findings
    }

    static func inspect(_ text: String, title: String, key: String, path: URL, modified: Date?, context: CheckContext,
                        recentDays: Int) -> [Finding] {
        var reasons: [String] = []
        var evidence: [String] = []
        var severity = Finding.Severity.info
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            for (reason, found) in matches(trimmed) {
                if !reasons.contains(reason) { reasons.append(reason) }
                if !evidence.contains(trimmed) { evidence.append(trimmed) }
                severity = max(severity, found)
            }
        }
        if reasons.isEmpty, let modified, context.now.timeIntervalSince(modified) < Double(recentDays) * 86_400 {
            return [Finding(category: .persistence, key: key, severity: .info, title: title, path: path,
                            reasons: ["Modificato di recente (\(modified.formatted(date: .numeric, time: .omitted))): controlla che sia opera tua"])]
        }
        guard !reasons.isEmpty else { return [] }
        return [Finding(category: .persistence, key: key, severity: severity, title: title, path: path, reasons: reasons,
                        evidence: evidence.prefix(20).map { String($0.prefix(300)) })]
    }
}
