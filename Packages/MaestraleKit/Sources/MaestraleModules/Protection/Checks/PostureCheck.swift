import Foundation
import MaestraleCore

/// System Settings deep links (macOS 14+).
public enum SettingsLinks {
    public static let fileVault = "x-apple.systempreferences:com.apple.preference.security?FDE"
    public static let gatekeeper = "x-apple.systempreferences:com.apple.preference.security?General"
    public static let firewall = "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"
    public static let softwareUpdate = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
    public static let usersAndGroups = "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
    public static let sharing = "x-apple.systempreferences:com.apple.Sharing-Settings.extension"
    public static let fullDiskAccess = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    public static let profiles = "x-apple.systempreferences:com.apple.Profiles-Settings.extension"
    public static let loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    public static let privacy = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
}

/// How macOS's own defenses are configured. Each weak setting is a finding
/// with a link to the right pane of System Settings.
public struct PostureCheck: ProtectionCheck {
    public let id = "posture"
    public let title = "Difese di macOS"
    let systemPreferences: URL
    let safariPreferences: URL?
    let currentUser: String

    public init(systemPreferences: URL = URL(fileURLWithPath: "/Library/Preferences"),
                safariPreferences: URL? = nil, currentUser: String = NSUserName()) {
        self.systemPreferences = systemPreferences
        self.safariPreferences = safariPreferences
        self.currentUser = currentUser
    }

    public func run(_ context: CheckContext) -> [Finding] {
        var findings: [Finding] = []
        func add(_ key: String, _ severity: Finding.Severity, _ title: String, _ reason: String, evidence: [String],
                 link: String) {
            findings.append(Finding(category: .defense, key: key, severity: severity, title: title, reasons: [reason],
                                    evidence: evidence.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                                    action: .openSettings(link)))
        }
        let commands = context.commands

        let fileVault = commands.run("/usr/bin/fdesetup", ["status"])
        if fileVault.contains("FileVault is Off") {
            add("filevault", .warning, "FileVault spento",
                "Il disco non è cifrato: chi prende il Mac può leggere tutti i file", evidence: [fileVault], link: SettingsLinks.fileVault)
        }

        let gatekeeper = commands.run("/usr/sbin/spctl", ["--status"])
        if gatekeeper.contains("disabled") {
            add("gatekeeper", .danger, "Gatekeeper disattivato",
                "Le app scaricate si aprono senza nessun controllo di firma o notarizzazione", evidence: [gatekeeper], link: SettingsLinks.gatekeeper)
        }

        let firewall = commands.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        if firewall.contains("disabled") || firewall.contains("State = 0") {
            add("firewall", .warning, "Firewall spento",
                "Le connessioni in entrata non vengono filtrate", evidence: [firewall], link: SettingsLinks.firewall)
        } else if !firewall.isEmpty {
            let stealth = commands.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getstealthmode"])
            if stealth.contains("off") {
                add("firewall-stealth", .info, "Modalità invisibile del firewall spenta",
                    "Il Mac risponde ai ping e alle scansioni di rete", evidence: [stealth], link: SettingsLinks.firewall)
            }
        }

        let updates = NSDictionary(contentsOf: systemPreferences.appendingPathComponent("com.apple.SoftwareUpdate.plist")) as? [String: Any] ?? [:]
        func isOff(_ key: String) -> Bool { (updates[key] as? Bool) == false || (updates[key] as? Int) == 0 }
        if isOff("AutomaticCheckEnabled") {
            add("updates-check", .warning, "Controllo automatico degli aggiornamenti spento",
                "macOS non cerca aggiornamenti da solo", evidence: ["AutomaticCheckEnabled = 0"], link: SettingsLinks.softwareUpdate)
        }
        if isOff("ConfigDataInstall") {
            add("updates-xprotect", .danger, "Aggiornamenti di sicurezza (XProtect) spenti",
                "Le definizioni antimalware di Apple non si aggiornano da sole", evidence: ["ConfigDataInstall = 0"], link: SettingsLinks.softwareUpdate)
        }
        if isOff("CriticalUpdateInstall") {
            add("updates-critical", .warning, "Risposte rapide di sicurezza spente",
                "Le patch urgenti di Apple non vengono installate automaticamente", evidence: ["CriticalUpdateInstall = 0"], link: SettingsLinks.softwareUpdate)
        }
        if isOff("AutomaticallyInstallMacOSUpdates") {
            add("updates-macos", .info, "Installazione automatica di macOS spenta",
                "Gli aggiornamenti di sistema vanno installati a mano", evidence: ["AutomaticallyInstallMacOSUpdates = 0"], link: SettingsLinks.softwareUpdate)
        }

        let loginWindow = NSDictionary(contentsOf: systemPreferences.appendingPathComponent("com.apple.loginwindow.plist")) as? [String: Any] ?? [:]
        if let user = loginWindow["autoLoginUser"] as? String, !user.isEmpty {
            add("auto-login", .warning, "Login automatico attivo",
                "All'accensione entra \(user) senza password", evidence: ["autoLoginUser = \(user)"], link: SettingsLinks.usersAndGroups)
        }
        if (loginWindow["GuestEnabled"] as? Bool) == true || (loginWindow["GuestEnabled"] as? Int) == 1 {
            add("guest", .info, "Account ospite attivo",
                "Chiunque può usare il Mac senza password", evidence: ["GuestEnabled = 1"], link: SettingsLinks.usersAndGroups)
        }

        for (label, name, key) in [("com.openssh.sshd", "Accesso remoto (SSH)", "ssh"),
                                   ("com.apple.screensharing", "Condivisione schermo", "screen-sharing")] {
            let output = commands.run("/bin/launchctl", ["print", "system/\(label)"])
            guard !output.isEmpty, !output.contains("Could not find") else { continue }
            add(key, .info, "\(name) attivo", "Il Mac accetta connessioni dalla rete: spegnilo se non lo usi",
                evidence: [output.components(separatedBy: "\n").first { $0.contains("state") } ?? label], link: SettingsLinks.sharing)
        }

        let admins = commands.run("/usr/bin/dscl", [".", "-read", "/Groups/admin", "GroupMembership"])
        if let line = admins.components(separatedBy: "\n").first(where: { $0.hasPrefix("GroupMembership:") }) {
            let others = line.dropFirst("GroupMembership:".count).split(separator: " ").map(String.init)
                .filter { $0 != "root" && $0 != currentUser && $0 != "_mbsetupuser" }
            if !others.isEmpty {
                add("admins", .info, "Altri amministratori: \(others.joined(separator: ", "))",
                    "Ogni amministratore può installare qualsiasi cosa: controlla che siano tutti tuoi", evidence: [line],
                    link: SettingsLinks.usersAndGroups)
            }
        }

        let safari = safariPreferences ?? context.home.appendingPathComponent(
            "Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist")
        if let prefs = NSDictionary(contentsOf: safari) as? [String: Any] {
            // Safari's default is to open "safe" downloads: that is how disk images
            // with a fake installer get mounted on their own.
            let value = prefs["AutoOpenSafeDownloads"]
            if (value as? Bool) != false && (value as? Int) != 0 {
                add("safari-auto-open", .warning, "Safari apre i file scaricati da solo",
                    "Immagini disco e archivi si aprono appena scaricati: spegnilo in Safari → Impostazioni → Generali",
                    evidence: ["AutoOpenSafeDownloads = \(value ?? "assente (predefinito: attivo)")"], link: "")
            }
        }
        return findings
    }
}
