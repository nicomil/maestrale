import Foundation
import MacCleanerCore

/// Big files in the user's folders, grouped by kind, plus old downloads.
/// Nothing is preselected: these are personal files.
public struct LargeOldFilesModule: CleanerModule {
    public let id = "large-old-files"
    public let title = "File grandi e vecchi"
    public var minimumSize: Int64
    public var oldDownloadDays: Int
    private let home: URL

    public init(minimumSize: Int64 = 50_000_000, oldDownloadDays: Int = 90,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.minimumSize = minimumSize
        self.oldDownloadDays = oldDownloadDays
        self.home = home
    }

    public var allowedRoots: [URL] { AllowedRoots.userFiles(home: home) }

    public func scan() async throws -> ScanReport {
        let downloads = PathUtils.realPath(home.appendingPathComponent("Downloads")) + "/"
        let oldLimit = Date().addingTimeInterval(-Double(oldDownloadDays) * 86_400)
        var oldDownloads: [ScanItem] = []
        var byKind: [FileKind: [ScanItem]] = [:]

        // Old downloads are listed from 1 MB, big files elsewhere from `minimumSize`.
        FileWalker(minimumSize: 1_000_000).walk(allowedRoots, shouldContinue: { !Task.isCancelled }) { file in
            let detail = RelativeAge.text(since: file.lastUsed).map { "Ultimo uso \($0)" }
            if file.url.path.hasPrefix(downloads), let used = file.lastUsed, used < oldLimit {
                oldDownloads.append(ScanItem(url: file.url, size: file.size, risk: .medium,
                                             autoSelect: false, needsHelper: false, detail: detail))
            } else if file.size >= minimumSize {
                byKind[FileKind.of(file.url), default: []].append(
                    ScanItem(url: file.url, size: file.size, risk: .high, autoSelect: false,
                             needsHelper: false, detail: detail))
            }
        }
        try Task.checkCancellation()

        var categories: [ScanCategory] = []
        if !oldDownloads.isEmpty {
            categories.append(ScanCategory(id: "old-downloads",
                                           title: "Download non usati da \(oldDownloadDays) giorni",
                                           items: oldDownloads.sorted { $0.size > $1.size }))
        }
        for kind in FileKind.allCases {
            guard let items = byKind[kind], !items.isEmpty else { continue }
            categories.append(ScanCategory(id: "large-\(kind.rawValue)", title: "\(kind.title) grandi",
                                           items: items.sorted { $0.size > $1.size }))
        }
        return ScanReport(moduleID: id, categories: categories)
    }
}
