import Foundation
import MaestraleCore

/// Browser extensions that can read every site, or that the browser did not
/// install from its store. Chromium browsers and Firefox.
public struct BrowserExtensionsCheck: ProtectionCheck {
    public let id = "browser-extensions"
    public let title = "Estensioni dei browser"

    public init() {}

    public func run(_ context: CheckContext) -> [Finding] {
        chromium(context) + firefox(context) + safari(context)
    }

    /// Safari extensions are app extensions registered with pluginkit. Their
    /// host app's signature is what matters: the extension inherits it.
    func safari(_ context: CheckContext) -> [Finding] {
        var findings: [Finding] = []
        for kind in ["com.apple.Safari.extension", "com.apple.Safari.web-extension", "com.apple.Safari.content-blocker"] {
            let output = context.commands.run("/usr/bin/pluginkit", ["-mAvvv", "-p", kind])
            for plugin in Self.parsePluginkit(output) {
                guard let path = plugin["Path"] else { continue }
                let signature = context.signatures.signature(of: URL(fileURLWithPath: path))
                let name = plugin["Display Name"] ?? plugin["id"] ?? path
                var reasons: [String] = []
                var severity = Finding.Severity.info
                let assessed = signature.assess(path: path)
                reasons += assessed.reasons
                severity = max(severity, assessed.severity)
                if KnownLocations.kind(of: path) != .normal {
                    reasons.append("Sta in una cartella temporanea o nascosta")
                    severity = .danger
                }
                if plugin["Parent Bundle"].map({ !$0.hasPrefix("/Applications/") && !$0.hasPrefix("/System/") }) ?? false {
                    reasons.append("L'app che la contiene non è in Applicazioni")
                    severity = max(severity, .warning)
                }
                guard !reasons.isEmpty else { continue }
                findings.append(Finding(category: .browser, key: "safari|\(plugin["id"] ?? path)", severity: severity,
                                        title: "Safari: \(name)", path: URL(fileURLWithPath: path), reasons: reasons,
                                        evidence: ["Tipo: \(kind)", "App: \(plugin["Parent Bundle"] ?? "?")"], team: signature.team))
            }
        }
        return findings
    }

    /// `pluginkit -mAvvv`: one block per plug-in, "   id(version)" then "Key = value" lines.
    static func parsePluginkit(_ text: String) -> [[String: String]] {
        var plugins: [[String: String]] = []
        var current: [String: String]?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "(no matches)" { continue }
            if let equals = line.range(of: " = "), current != nil {
                current?[String(line[..<equals.lowerBound])] = String(line[equals.upperBound...])
            } else if line.contains("(") {
                if let current { plugins.append(current) }
                let id = line.components(separatedBy: "(").first ?? line
                current = ["id": id.trimmingCharacters(in: CharacterSet(charactersIn: "+-! ")).trimmingCharacters(in: .whitespaces)]
            }
        }
        if let current { plugins.append(current) }
        return plugins
    }

    func chromium(_ context: CheckContext) -> [Finding] {
        var findings: [Finding] = []
        let support = context.home.appendingPathComponent("Library/Application Support")
        for browser in PrivacyScanner.chromium {
            let base = support.appendingPathComponent(browser.folder)
            for profile in PrivacyScanner(home: context.home).chromiumProfiles(base) {
                let extensions = base.appendingPathComponent("\(profile)/Extensions")
                let installs = Self.extensionSettings(profile: base.appendingPathComponent(profile))
                for id in (try? FileManager.default.contentsOfDirectory(atPath: extensions.path)) ?? [] {
                    let folder = extensions.appendingPathComponent(id)
                    guard let version = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().last,
                          let text = context.text(of: folder.appendingPathComponent("\(version)/manifest.json"), limit: 2_000_000),
                          let manifest = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                    let permissions = ((manifest["permissions"] as? [Any]) ?? []) + ((manifest["host_permissions"] as? [Any]) ?? [])
                    let strings = permissions.compactMap { $0 as? String }
                    let readsAll = strings.contains { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0 == "http://*/*" || $0 == "https://*/*" }
                    // The manifest is written by whoever made the extension, so its
                    // update_url proves nothing. Only the browser's own record counts.
                    let fromStore = installs[id].map(Self.isFromWebStore) ?? false
                    guard readsAll || !fromStore else { continue }
                    var name = manifest["name"] as? String ?? id
                    if name.hasPrefix("__MSG_") { name = id }
                    var reasons: [String] = []
                    if readsAll { reasons.append("Può leggere e modificare tutti i siti") }
                    if !fromStore { reasons.append("Installazione dallo store non verificata") }
                    let evidence = ["ID: \(id)", "Versione: \(version)"] + strings.map { "Permesso: \($0)" }
                    findings.append(Finding(category: .browser, key: folder.path, severity: fromStore ? .info : .warning,
                                            title: "\(browser.name): \(name)", path: folder, reasons: reasons, evidence: evidence,
                                            action: .trash))
                }
            }
        }
        return findings
    }

    /// Firefox keeps the list of add-ons, with their origin, in each profile's extensions.json.
    func firefox(_ context: CheckContext) -> [Finding] {
        var findings: [Finding] = []
        let profiles = context.home.appendingPathComponent("Library/Application Support/Firefox/Profiles")
        for profile in (try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? [] {
            let folder = profiles.appendingPathComponent(profile)
            guard let text = context.text(of: folder.appendingPathComponent("extensions.json"), limit: 5_000_000),
                  let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let addons = root["addons"] as? [[String: Any]] else { continue }
            for addon in addons {
                guard addon["type"] as? String == "extension", addon["active"] as? Bool != false,
                      addon["location"] as? String != "app-builtin", addon["location"] as? String != "app-system-defaults" else { continue }
                let id = addon["id"] as? String ?? "?"
                let name = (addon["defaultLocale"] as? [String: Any])?["name"] as? String ?? id
                let permissions = (addon["userPermissions"] as? [String: Any])?["origins"] as? [String] ?? []
                let readsAll = permissions.contains { $0 == "<all_urls>" || $0.hasPrefix("*://*/") }
                // Firefox signs every add-on installed from addons.mozilla.org.
                let signed = (addon["signedState"] as? Int ?? 0) > 0
                let sideloaded = addon["location"] as? String != "app-profile"
                guard readsAll || !signed || sideloaded else { continue }
                var reasons: [String] = []
                if readsAll { reasons.append("Può leggere e modificare tutti i siti") }
                if !signed { reasons.append("Non firmata da Mozilla") }
                if sideloaded { reasons.append("Installata fuori dal profilo (\(addon["location"] as? String ?? "?"))") }
                let path = (addon["path"] as? String).map { URL(fileURLWithPath: $0) }
                findings.append(Finding(category: .browser, key: "firefox/\(profile)/\(id)", severity: signed && !sideloaded ? .info : .warning,
                                        title: "Firefox: \(name)", path: path, reasons: reasons,
                                        evidence: ["ID: \(id)", "Profilo: \(profile)"] + permissions.map { "Origine: \($0)" },
                                        action: path == nil ? .none : .trash))
            }
        }
        return findings
    }

    /// What the browser recorded about each installed extension, from the
    /// profile's "Secure Preferences" (signed by the browser) and "Preferences".
    static func extensionSettings(profile: URL) -> [String: [String: Any]] {
        var settings: [String: [String: Any]] = [:]
        for name in ["Preferences", "Secure Preferences"] {
            guard let data = try? Data(contentsOf: profile.appendingPathComponent(name)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = (root["extensions"] as? [String: Any])?["settings"] as? [String: Any] else { continue }
            for case let (id, value as [String: Any]) in entries {
                settings[id, default: [:]].merge(value) { _, new in new }
            }
        }
        return settings
    }

    /// True when the browser itself marked the extension as installed from its
    /// store: `from_webstore`, or the FROM_WEBSTORE bit (8) of `creation_flags`.
    /// Chromium writes both (extensions/browser/extension_prefs.cc,
    /// `PopulateExtensionInfoPrefs`; the bit is in extensions/common/extension.h).
    static func isFromWebStore(_ entry: [String: Any]) -> Bool {
        if entry["from_webstore"] as? Bool == true { return true }
        if let flags = entry["creation_flags"] as? Int, flags & 8 != 0 { return true }
        return false
    }
}
