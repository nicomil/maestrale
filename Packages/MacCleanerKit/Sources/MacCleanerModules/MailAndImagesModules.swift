import Foundation
import MacCleanerCore

/// Local copies of Mail attachments. Mail downloads them again from the
/// server when a message is opened (IMAP and Exchange accounts; not POP).
/// Local "On My Mac" mailboxes (~/Library/Mail/V*/Mailboxes) are skipped:
/// there is no server to download those attachments from.
public struct MailAttachmentsModule: CleanerModule {
    public let id = "mail-attachments"
    public let title = "Allegati di Mail"
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public var allowedRoots: [URL] {
        [home.appendingPathComponent("Library/Mail"),
         home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")]
    }

    /// ~/Library/Mail/V*/<account>/<mailbox>.mbox/…/Attachments/<message id>
    static func attachmentFolders(in mail: URL) -> [ScanItem] {
        var result: [ScanItem] = []
        guard let enumerator = FileManager.default.enumerator(at: mail, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles], errorHandler: { _, _ in true })
        else { return [] }
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            if url.lastPathComponent == "Mailboxes", url.deletingLastPathComponent().lastPathComponent.hasPrefix("V") {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "Attachments" else { continue }
            enumerator.skipDescendants()
            for message in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                let size = FileSizer.allocatedSize(of: message)
                guard size > 0 else { continue }
                let names = ((try? FileManager.default.subpathsOfDirectory(atPath: message.path)) ?? [])
                    .map { ($0 as NSString).lastPathComponent }.filter { $0.contains(".") }
                result.append(ScanItem(url: message, size: size, risk: .medium, autoSelect: false,
                                       needsHelper: false, detail: names.prefix(3).joined(separator: ", ")))
            }
        }
        return result
    }

    public func scan() async throws -> ScanReport {
        let mail = home.appendingPathComponent("Library/Mail")
        var unreadable: [URL] = []
        var attachments: [ScanItem] = []
        if FileManager.default.fileExists(atPath: mail.path),
           (try? FileManager.default.contentsOfDirectory(atPath: mail.path)) == nil {
            unreadable.append(mail)
        }
        attachments = Self.attachmentFolders(in: mail)
        try Task.checkCancellation()
        var categories: [ScanCategory] = []
        if !attachments.isEmpty {
            categories.append(ScanCategory(id: "mail-attachments", title: "Allegati scaricati",
                                           items: attachments.sorted { $0.size > $1.size }))
        }
        let downloads = home.appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        let downloaded = ((try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? [])
            .map { ScanItem(url: $0, size: FileSizer.allocatedSize(of: $0), risk: .low, autoSelect: true, needsHelper: false) }
            .filter { $0.size > 0 }
        if !downloaded.isEmpty {
            categories.append(ScanCategory(id: "mail-downloads", title: "Allegati aperti da Mail",
                                           items: downloaded.sorted { $0.size > $1.size }))
        }
        return ScanReport(moduleID: id, categories: categories, unreadablePaths: unreadable)
    }
}

/// Disk images and installers left in the user's folders after installing.
public struct InstallersModule: CleanerModule {
    public let id = "installers"
    public let title = "Installer e immagini disco"
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Where installers usually end up. Project folders are left alone: a
    /// `.pkg` in a build folder is the user's work, not a leftover.
    public var allowedRoots: [URL] {
        ["Downloads", "Desktop", "Documents"].map { home.appendingPathComponent($0) }
    }

    public func scan() async throws -> ScanReport {
        let installedNames = Set(AppInventory(home: home).appURLs().map {
            Self.normalized($0.deletingPathExtension().lastPathComponent)
        }.filter { $0.count >= 4 })
        let mounted = Self.mountedImagePaths()
        var installed: [ScanItem] = []
        var other: [ScanItem] = []

        FileWalker(minimumSize: 1_000_000).walk(allowedRoots, shouldContinue: { !Task.isCancelled }) { file in
            guard FileKind.of(file.url) == .diskImage, !mounted.contains(file.url.path) else { return }
            let name = Self.normalized(file.url.deletingPathExtension().lastPathComponent)
            // "Spotify-1.2.dmg", "Install Spotify.dmg"; a plain "contains" only for long names.
            // A name like the app's proves nothing ("Spotify backup.dmg"): only files
            // macOS marked as downloaded from the internet can be leftover installers.
            let match = Self.isInstallerFormat(file.url) && Self.wasDownloaded(file.url) ? installedNames.first {
                name.hasPrefix($0) || name.hasPrefix("install" + $0) || ($0.count >= 7 && name.contains($0))
            } : nil
            let age = RelativeAge.text(since: file.modified).map { "scaricato \($0)" } ?? ""
            if let match {
                installed.append(ScanItem(url: file.url, size: file.size, risk: .low, autoSelect: true,
                                          needsHelper: false, detail: "App già installata (\(match)) · \(age)"))
            } else {
                other.append(ScanItem(url: file.url, size: file.size, risk: .medium, autoSelect: false,
                                      needsHelper: false, detail: age))
            }
        }
        try Task.checkCancellation()
        var categories: [ScanCategory] = []
        if !installed.isEmpty {
            categories.append(ScanCategory(id: "installed", title: "Installer di app già installate",
                                           items: installed.sorted { $0.size > $1.size }))
        }
        if !other.isEmpty {
            categories.append(ScanCategory(id: "other-images", title: "Altre immagini disco e pacchetti",
                                           items: other.sorted { $0.size > $1.size }))
        }
        return ScanReport(moduleID: id, categories: categories)
    }

    /// Only plain .dmg and .pkg files can be treated as leftover installers.
    /// Sparse images, .img and .iso files, and encrypted disk images are
    /// usually the user's own data, so they are never preselected.
    static func isInstallerFormat(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "pkg", "mpkg": return true
        case "dmg": return !isEncryptedImage(url)
        default: return false
        }
    }

    /// True when the file carries the quarantine mark that browsers, Mail and
    /// AirDrop add to downloads. Disk images the user made never have it.
    static func wasDownloaded(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// True unless `hdiutil` says plainly that the image is not encrypted.
    static func isEncryptedImage(_ url: URL) -> Bool {
        !SystemCommands().run("/usr/bin/hdiutil", ["isencrypted", url.path]).contains("encrypted: NO")
    }

    /// "Visual Studio Code" and "VSCode-darwin-arm64" both start with letters only, lowercased.
    static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func mountedImagePaths() -> Set<String> {
        let output = SystemCommands().run("/usr/bin/hdiutil", ["info"])
        return Set(output.components(separatedBy: "\n").compactMap { line in
            line.hasPrefix("image-path") ? line.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
                .trimmingCharacters(in: .whitespaces) : nil
        })
    }
}
