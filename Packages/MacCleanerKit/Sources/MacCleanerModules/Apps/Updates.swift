import Foundation

/// Where an update comes from.
public enum UpdateSource: String, Sendable {
    case sparkle = "Sparkle"
    case appStore = "App Store"
    case homebrew = "Homebrew"
}

public struct AppUpdate: Identifiable, Sendable, Hashable {
    public var id: URL { app.url }
    public let app: InstalledApp
    public let availableVersion: String
    /// The build number of the update (`sparkle:version`), when the feed gives one.
    public let availableBuild: String?
    public let source: UpdateSource
    /// Release notes or store page.
    public let infoURL: URL?
    /// Homebrew cask token, when the source is Homebrew.
    public let caskToken: String?

    public init(app: InstalledApp, availableVersion: String, availableBuild: String? = nil, source: UpdateSource,
                infoURL: URL?, caskToken: String?) {
        self.app = app
        self.availableVersion = availableVersion
        self.availableBuild = availableBuild
        self.source = source
        self.infoURL = infoURL
        self.caskToken = caskToken
    }

    /// Whether the update is still due for the app as it is on disk now: the
    /// same comparison the check made, repeated after the user updated.
    public func isStillPending(for installed: InstalledApp) -> Bool {
        switch source {
        case .sparkle:
            if let availableBuild {
                return Version.isNewer(availableBuild, than: installed.build)
                    && !Version.isNewer(installed.version, than: availableVersion)
            }
            return Version.isNewer(availableVersion, than: installed.version)
        case .appStore:
            return Version.isNewer(availableVersion, than: installed.version)
        case .homebrew:
            // "latest" and other non-numeric cask versions cannot be compared: trust brew.
            return Version.normalized(availableVersion).isEmpty || Version.isNewer(availableVersion, than: installed.version)
        }
    }
}

/// Compares version strings numerically ("1.10" > "1.9", "2.0.1" > "2.0").
public enum Version {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = normalized(candidate), b = normalized(current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.compare(b, options: .numeric) == .orderedDescending
    }

    static func normalized(_ v: String) -> String {
        // Keep "1.2.3" out of "1.2.3 (456)" or "v1.2.3-beta".
        var s = v.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let allowed = s.prefix { $0.isNumber || $0 == "." }
        return String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

/// Reads a Sparkle appcast and returns the newest item usable on this macOS.
public enum Appcast {
    public struct Item: Sendable {
        public let version: String
        public let shortVersion: String?
        public let minimumSystemVersion: String?
        public let releaseNotes: URL?
    }

    public static func parse(_ data: Data) -> [Item] {
        let parser = AppcastParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.items
    }

    public static func newest(_ items: [Item], systemVersion: String) -> Item? {
        items
            .filter { item in
                guard let min = item.minimumSystemVersion else { return true }
                return !Version.isNewer(min, than: systemVersion)
            }
            // sparkle:version is always present and comparable across items.
            .max { Version.isNewer($1.version, than: $0.version) }
    }
}

private final class AppcastParser: NSObject, XMLParserDelegate {
    var items: [Appcast.Item] = []
    private var inItem = false
    private var text = ""
    private var version: String?
    private var shortVersion: String?
    private var minSystem: String?
    private var notes: URL?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "item" {
            inItem = true
            version = nil; shortVersion = nil; minSystem = nil; notes = nil
        } else if inItem && name == "enclosure" {
            version = version ?? attributes["sparkle:version"]
            shortVersion = shortVersion ?? attributes["sparkle:shortVersionString"]
            minSystem = minSystem ?? attributes["sparkle:minimumSystemVersion"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inItem else { return }
        switch name {
        case "sparkle:version": version = value
        case "sparkle:shortVersionString": shortVersion = value
        case "sparkle:minimumSystemVersion": minSystem = value
        case "sparkle:releaseNotesLink": notes = URL(string: value)
        case "item":
            inItem = false
            if let version { items.append(.init(version: version, shortVersion: shortVersion,
                                                minimumSystemVersion: minSystem, releaseNotes: notes)) }
        default: break
        }
    }
}

/// Checks installed apps for updates from Sparkle feeds, the App Store
/// (iTunes lookup) and Homebrew casks.
public struct UpdateChecker: Sendable {
    public var countryCode: String
    public var brewPath: String

    public init(countryCode: String = Locale.current.region?.identifier.lowercased() ?? "us",
                brewPath: String = "/opt/homebrew/bin/brew") {
        self.countryCode = countryCode
        self.brewPath = brewPath
    }

    public func check(_ apps: [InstalledApp]) async -> [AppUpdate] {
        async let sparkle = sparkleUpdates(apps.filter { $0.sparkleFeed != nil && !$0.isAppStore })
        async let store = appStoreUpdates(apps.filter(\.isAppStore))
        async let brew = homebrewUpdates(apps)
        var byApp: [URL: AppUpdate] = [:]
        // Homebrew first, so a Sparkle or App Store result for the same app wins.
        for update in await brew + sparkle + store { byApp[update.app.url] = update }
        return byApp.values.sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    func sparkleUpdates(_ apps: [InstalledApp]) async -> [AppUpdate] {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        return await withTaskGroup(of: AppUpdate?.self) { group in
            for app in apps {
                group.addTask {
                    guard let feed = app.sparkleFeed, feed.scheme == "https",
                          let data = try? await Self.fetch(feed),
                          let newest = Appcast.newest(Appcast.parse(data), systemVersion: systemVersion)
                    else { return nil }
                    // Compare build numbers when the feed gives them, else marketing versions.
                    let newer = Version.isNewer(newest.version, than: app.build)
                        && (newest.shortVersion.map { !Version.isNewer(app.version, than: $0) } ?? true)
                    guard newer else { return nil }
                    return AppUpdate(app: app, availableVersion: newest.shortVersion ?? newest.version,
                                     availableBuild: newest.version, source: .sparkle,
                                     infoURL: newest.releaseNotes, caskToken: nil)
                }
            }
            var result: [AppUpdate] = []
            for await update in group { if let update { result.append(update) } }
            return result
        }
    }

    func appStoreUpdates(_ apps: [InstalledApp]) async -> [AppUpdate] {
        guard !apps.isEmpty else { return [] }
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        var result: [AppUpdate] = []
        for batch in stride(from: 0, to: apps.count, by: 50).map({ Array(apps[$0..<min($0 + 50, apps.count)]) }) {
            let ids = batch.map(\.bundleID).joined(separator: ",")
            guard let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(ids)&country=\(countryCode)&entity=macSoftware"),
                  let data = try? await Self.fetch(url) else { continue }
            let found = Self.parseLookup(data)
            for app in batch {
                guard let entry = found[app.bundleID], entry.isInstallable(on: systemVersion),
                      Version.isNewer(entry.version, than: app.version) else { continue }
                result.append(AppUpdate(app: app, availableVersion: entry.version, source: .appStore,
                                        infoURL: entry.page, caskToken: nil))
            }
        }
        return result
    }

    /// One result of the iTunes lookup.
    public struct StoreEntry: Sendable, Equatable {
        public let version: String
        /// The app in the App Store app (`macappstore://`), or the web page.
        public let page: URL?
        public let minimumOSVersion: String?

        /// The store only offers the update on a system new enough for it:
        /// listing it elsewhere would send the user to a page with no update.
        public func isInstallable(on systemVersion: String) -> Bool {
            guard let minimumOSVersion else { return true }
            return !Version.isNewer(minimumOSVersion, than: systemVersion)
        }
    }

    public static func parseLookup(_ data: Data) -> [String: StoreEntry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [:] }
        var map: [String: StoreEntry] = [:]
        for entry in results {
            guard let id = entry["bundleId"] as? String, let version = entry["version"] as? String else { continue }
            let web = (entry["trackViewUrl"] as? String).flatMap(URL.init(string:))
            let store = (entry["trackId"] as? NSNumber).flatMap { URL(string: "macappstore://apps.apple.com/app/id\($0.int64Value)") }
            map[id] = StoreEntry(version: version, page: store ?? web, minimumOSVersion: entry["minimumOsVersion"] as? String)
        }
        return map
    }

    func homebrewUpdates(_ apps: [InstalledApp]) async -> [AppUpdate] {
        guard FileManager.default.isExecutableFile(atPath: brewPath),
              let data = Self.run(brewPath, ["outdated", "--cask", "--greedy", "--json=v2"]) else { return [] }
        let outdated = Self.parseBrewOutdated(data)
        guard !outdated.isEmpty,
              let infoData = Self.run(brewPath, ["info", "--cask", "--json=v2"] + outdated.map(\.token)) else { return [] }
        let appNames = Self.parseBrewAppNames(infoData)
        var result: [AppUpdate] = []
        for cask in outdated {
            for appName in appNames[cask.token] ?? [] {
                guard let app = apps.first(where: { $0.url.lastPathComponent == appName }) else { continue }
                let update = AppUpdate(app: app, availableVersion: cask.version, source: .homebrew,
                                       infoURL: nil, caskToken: cask.token)
                // `--greedy` also lists casks whose app updated itself: brew's
                // record is old, the app is not. Only what is really older counts.
                guard update.isStillPending(for: app) else { continue }
                result.append(update)
            }
        }
        return result
    }

    static func parseBrewOutdated(_ data: Data) -> [(token: String, version: String)] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else { return [] }
        return casks.compactMap { cask in
            guard let token = cask["name"] as? String, let version = cask["current_version"] as? String else { return nil }
            return (token, version)
        }
    }

    static func parseBrewAppNames(_ data: Data) -> [String: [String]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = json["casks"] as? [[String: Any]] else { return [:] }
        var map: [String: [String]] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String, let artifacts = cask["artifacts"] as? [[String: Any]] else { continue }
            map[token] = artifacts.compactMap { $0["app"] as? [Any] }.flatMap { $0.compactMap { $0 as? String } }
        }
        return map
    }

    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("MacCleaner/1.0 (personal)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    static func run(_ tool: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}
