import Foundation
import MaestraleCore

extension SystemEvidence {
    /// The one privileged, read-only command: fixed sections, no arguments from
    /// outside, output parsed by the checks that need root.
    public static let shellCommand: String = [
        "echo '### crontabs'; for f in /usr/lib/cron/tabs/* /var/at/jobs/*; do [ -f \"$f\" ] && echo \"## $f\" && /bin/cat \"$f\"; done 2>/dev/null",
        "echo '### profiles'; /usr/bin/profiles show -type configuration -output stdout-xml 2>/dev/null",
        "echo '### tcc'; /usr/bin/sqlite3 -separator '|' '/Library/Application Support/com.apple.TCC/TCC.db' 'select service, client, client_type, auth_value from access' 2>/dev/null",
        "echo '### lsof'; /usr/sbin/lsof -i -n -P 2>/dev/null",
        "echo '### sudoers'; for f in /etc/sudoers.d/*; do [ -f \"$f\" ] && echo \"## $f\" && /bin/cat \"$f\"; done 2>/dev/null",
        "exit 0",
    ].joined(separator: "; ")

    /// Splits the command's output on its "### name" headers.
    public static func parse(_ text: String) -> SystemEvidence {
        var sections: [String: String] = [:]
        var current: String?
        var lines: [String] = []
        func flush() { if let current { sections[current] = lines.joined(separator: "\n") } }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("### ") {
                flush()
                current = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                lines = []
            } else {
                lines.append(String(line))
            }
        }
        flush()
        return SystemEvidence(sections: sections)
    }

    public subscript(_ name: String) -> String? { sections[name] }
}
