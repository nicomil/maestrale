import CoreServices
import Foundation
import MacCleanerCore
import Security

/// An application bundle found on disk.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String
    public let build: String
    public let teamID: String?
    public let size: Int64
    public let lastUsed: Date?
    public let isAppStore: Bool
    public let sparkleFeed: URL?
    /// Bundle identifiers of the extensions, helpers and login items inside the app.
    public let embeddedBundleIDs: [String]

    public var isApple: Bool { bundleID.hasPrefix("com.apple.") }
    public var isWritable: Bool { FileManager.default.isDeletableFile(atPath: url.path) }
}

/// Finds the applications installed in /Applications and ~/Applications.
public struct AppInventory: Sendable {
    public let folders: [URL]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, folders: [URL]? = nil) {
        self.folders = folders ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    /// App bundles in the folders and one level of subfolders (e.g. Utilities).
    public func appURLs() -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for folder in folders {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(".") {
                let url = folder.appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    result.append(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    for inner in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] where inner.hasSuffix(".app") {
                        result.append(url.appendingPathComponent(inner))
                    }
                }
            }
        }
        return result
    }

    /// Reads every app, computing sizes in parallel.
    public func load(computeSizes: Bool = true) async -> [InstalledApp] {
        let urls = appURLs()
        return await withTaskGroup(of: InstalledApp?.self) { group in
            var pending = urls.makeIterator()
            var apps: [InstalledApp] = []
            // At most 6 apps measured at once, to keep the disk responsive.
            for _ in 0..<6 {
                guard let url = pending.next() else { break }
                group.addTask { Self.read(url, computeSize: computeSizes) }
            }
            for await app in group {
                if let app { apps.append(app) }
                if let url = pending.next() { group.addTask { Self.read(url, computeSize: computeSizes) } }
            }
            return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    public static func read(_ url: URL, computeSize: Bool = true) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let feed = (info["SUFeedURL"] as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
        let receipt = url.appendingPathComponent("Contents/_MASReceipt/receipt")
        return InstalledApp(
            url: url, name: name, bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? "",
            teamID: teamIdentifier(url),
            size: computeSize ? FileSizer.allocatedSize(of: url) : 0,
            lastUsed: lastUsedDate(url),
            isAppStore: FileManager.default.fileExists(atPath: receipt.path),
            sparkleFeed: feed,
            embeddedBundleIDs: embeddedBundleIDs(url)
        )
    }

    static func embeddedBundleIDs(_ url: URL) -> [String] {
        let places = ["Contents/PlugIns", "Contents/Library/LoginItems", "Contents/XPCServices",
                      "Contents/Library/LaunchServices", "Contents/Helpers", "Contents/Extensions"]
        var ids: [String] = []
        for place in places {
            let folder = url.appendingPathComponent(place)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                if let id = Bundle(url: folder.appendingPathComponent(name))?.bundleIdentifier {
                    ids.append(id)
                } else if name.split(separator: ".").count >= 3 {
                    ids.append(name) // helper tools named like a bundle id (com.vendor.helper)
                }
            }
        }
        return ids
    }

    static func teamIdentifier(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
