import Foundation
import MaestraleCore

/// Home page, start-up pages and search engine of the browsers: the first
/// things adware changes.
public struct BrowserHijackCheck: ProtectionCheck {
    public let id = "browser-hijack"
    public let title = "Dirottamento del browser"

    public init() {}

    static let knownSearchHosts = ["google.", "bing.com", "duckduckgo.com", "ecosia.org", "yahoo.com", "qwant.com",
                                   "startpage.com", "brave.com", "search.brave.com", "yandex.", "baidu.com", "kagi.com",
                                   "perplexity.ai", "you.com", "microsoft.com"]

    public func run(_ context: CheckContext) -> [Finding] {
        var findings: [Finding] = []
        let support = context.home.appendingPathComponent("Library/Application Support")
        for browser in PrivacyScanner.chromium {
            let base = support.appendingPathComponent(browser.folder)
            for profile in PrivacyScanner(home: context.home).chromiumProfiles(base) {
                let file = base.appendingPathComponent("\(profile)/Preferences")
                guard let text = context.text(of: file, limit: 20_000_000),
                      let prefs = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                findings += Self.chromiumFindings(prefs, browser: browser.name, profile: profile, path: file)
            }
        }
        let safari = context.home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist")
        if let prefs = NSDictionary(contentsOf: safari) as? [String: Any] {
            if let home = prefs["HomePage"] as? String, let host = URL(string: home)?.host, !Self.isKnownHost(host), !Self.isLocal(host) {
                findings.append(Finding(category: .browser, key: "safari|homepage", severity: .warning, title: "Safari: pagina iniziale",
                                        path: safari, reasons: ["Pagina iniziale impostata su \(host)"], evidence: ["HomePage = \(home)"]))
            }
            if let engine = prefs["SearchProviderIdentifier"] as? String, !engine.isEmpty,
               !["com.google.www", "com.bing", "com.duckduckgo", "com.yahoo", "com.ecosia"].contains(where: { engine.hasPrefix($0) }) {
                findings.append(Finding(category: .browser, key: "safari|search", severity: .warning, title: "Safari: motore di ricerca",
                                        path: safari, reasons: ["Motore di ricerca non standard: \(engine)"], evidence: ["SearchProviderIdentifier = \(engine)"]))
            }
        }
        return findings
    }

    static func chromiumFindings(_ prefs: [String: Any], browser: String, profile: String, path: URL) -> [Finding] {
        var findings: [Finding] = []
        let prefix = "\(browser)/\(profile)"
        if let home = prefs["homepage"] as? String, prefs["homepage_is_newtabpage"] as? Bool != true,
           let host = URL(string: home)?.host, !isKnownHost(host), !isLocal(host) {
            findings.append(Finding(category: .browser, key: "\(prefix)|homepage", severity: .warning, title: "\(browser): pagina iniziale",
                                    path: path, reasons: ["Pagina iniziale impostata su \(host)"], evidence: ["homepage = \(home)", "Profilo: \(profile)"]))
        }
        if let session = prefs["session"] as? [String: Any], session["restore_on_startup"] as? Int == 4,
           let urls = session["startup_urls"] as? [String] {
            let odd = urls.filter { URL(string: $0)?.host.map { !isKnownHost($0) && !isLocal($0) } ?? false }
            if !odd.isEmpty {
                findings.append(Finding(category: .browser, key: "\(prefix)|startup", severity: .warning, title: "\(browser): pagine di avvio",
                                        path: path, reasons: ["All'avvio apre \(odd.count) pagine impostate da qualcuno"],
                                        evidence: odd.map { "startup_urls: \($0)" } + ["Profilo: \(profile)"]))
            }
        }
        if let data = (prefs["default_search_provider_data"] as? [String: Any])?["template_url_data"] as? [String: Any],
           let url = data["url"] as? String, let host = URL(string: url.replacingOccurrences(of: "{searchTerms}", with: "x"))?.host,
           !isKnownHost(host) {
            findings.append(Finding(category: .browser, key: "\(prefix)|search", severity: .danger, title: "\(browser): motore di ricerca",
                                    path: path, reasons: ["Le ricerche passano da \(host) invece che da un motore conosciuto"],
                                    evidence: ["Nome: \(data["short_name"] as? String ?? "?")", "URL: \(url)", "Profilo: \(profile)"]))
        }
        return findings
    }

    static func isKnownHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return knownSearchHosts.contains { lower == $0 || lower.hasSuffix("." + $0) || lower.contains($0) }
    }

    static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host.hasPrefix("127.") || host.hasSuffix(".local") || host.hasSuffix(".test")
    }
}
