import CoreGraphics
import Foundation
import MacCleanerCore
import Testing
@testable import MacCleanerModules

/// Temporary fake home folder for module tests.
struct FakeHome {
    let url: URL

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccleaner-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        url = raw.resolvingSymlinksInPath()
    }

    @discardableResult
    func file(_ relative: String, bytes: Int, fill: UInt8 = 7, modified: Date? = nil) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: target)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
            // Access date too, so "last used" is really old.
            var times = [timespec(tv_sec: Int(modified.timeIntervalSince1970), tv_nsec: 0),
                         timespec(tv_sec: Int(modified.timeIntervalSince1970), tv_nsec: 0)]
            utimensat(AT_FDCWD, target.path, &times, 0)
        }
        return target
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Suite struct SpaceModulesTests {
    @Test func treemapAreasAreProportionalAndInside() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let values: [Double] = [60, 30, 6, 3, 1]
        let tiles = Treemap.layout(values, in: rect)
        let total = values.reduce(0, +)
        for (value, tile) in zip(values, tiles) {
            #expect(abs(tile.width * tile.height - value / total * rect.width * rect.height) < 1)
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(tile))
        }
    }

    @Test func largeOldFilesGroupsByKindAndFindsOldDownloads() async throws {
        let home = try FakeHome(); defer { home.remove() }
        try home.file("Movies/film.mov", bytes: 3_000_000)
        try home.file("Documents/small.mov", bytes: 100_000)
        try home.file("Downloads/old.zip", bytes: 2_000_000, modified: Date(timeIntervalSinceNow: -200 * 86_400))
        try home.file("Downloads/new.zip", bytes: 2_000_000)
        try home.file("Library/Caches/huge.bin", bytes: 3_000_000)

        let report = try await LargeOldFilesModule(minimumSize: 1_500_000, home: home.url).scan()
        let byCategory = Dictionary(uniqueKeysWithValues: report.categories.map { ($0.id, $0.items.map(\.displayName)) })
        #expect(byCategory["old-downloads"] == ["old.zip"])
        #expect(byCategory["large-video"] == ["film.mov"])
        #expect(byCategory["large-archive"] == ["new.zip"])
        #expect(!report.allItems.contains { $0.url.path.contains("/Library/") })
        #expect(!report.allItems.contains { $0.autoSelect })
    }

    @Test func duplicatesKeepOneCopyAndIgnoreHardLinks() async throws {
        let home = try FakeHome(); defer { home.remove() }
        let original = try home.file("Documents/report.pdf", bytes: 1_200_000, fill: 1)
        try home.file("Downloads/report.pdf", bytes: 1_200_000, fill: 1)
        try home.file("Desktop/report copy.pdf", bytes: 1_200_000, fill: 1)
        try home.file("Documents/other.pdf", bytes: 1_200_000, fill: 2) // same size, different content
        try FileManager.default.linkItem(at: original, to: home.url.appendingPathComponent("Documents/hardlink.pdf"))

        let report = try await DuplicatesModule(home: home.url).scan()
        #expect(report.categories.count == 1)
        let items = try #require(report.categories.first?.items)
        #expect(items.count == 3)
        #expect(items.filter { !$0.autoSelect }.count == 1)
        let kept = try #require(items.first { !$0.autoSelect })
        #expect(!kept.url.path.contains("/Downloads/"))
    }

    @Test func similarImageClustering() {
        let a: UInt64 = 0b1011_0000
        let groups = SimilarImagesModule.cluster([a, a ^ 0b1, a ^ 0b11, ~a], maxDistance: 2)
        #expect(groups.count == 1)
        #expect(Set(groups[0]) == [0, 1, 2])
    }

    @Test func spaceLensSizesAndSmallFileGrouping() async throws {
        let home = try FakeHome(); defer { home.remove() }
        try home.file("big/a.bin", bytes: 2_000_000)
        try home.file("big/tiny1.txt", bytes: 10_000)
        try home.file("big/tiny2.txt", bytes: 10_000)
        try home.file("other/b.bin", bytes: 1_000_000)

        let root = await SpaceLensScanner(minimumFileSize: 500_000).scan(home.url)
        #expect(root.children.map(\.name) == ["big", "other"])
        let big = root.children[0]
        #expect(big.children.contains { $0.isAggregate && $0.fileCount == 2 })
        #expect(root.size == root.children.reduce(0) { $0 + $1.size })
        #expect(root.fileCount == 4)
    }
}
