import CoreGraphics
import Foundation
import ImageIO
import MacCleanerCore

/// Photos that look alike (same shot saved twice, resized copies, bursts).
///
/// Each image gets a 64-bit difference hash (dHash) from a tiny 9×8 grayscale
/// thumbnail; images whose hashes differ in at most `maxDistance` bits are
/// grouped. The biggest image of a group is kept. Similar is not identical,
/// so nothing is preselected. The Photos library is never touched.
public struct SimilarImagesModule: CleanerModule {
    public let id = "similar-images"
    public let title = "Immagini simili"
    public var maxDistance: Int
    private let roots: [URL]

    public init(maxDistance: Int = 5, roots: [URL]? = nil,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.maxDistance = maxDistance
        self.roots = roots ?? AllowedRoots.userFiles(home: home)
    }

    public var allowedRoots: [URL] { roots }

    struct Entry {
        let file: FileRecord
        let hash: UInt64
        let pixels: Int
    }

    public func scan() async throws -> ScanReport {
        var entries: [Entry] = []
        FileWalker(minimumSize: 30_000).walk(roots, shouldContinue: { !Task.isCancelled }) { file in
            guard FileKind.of(file.url) == .image,
                  let (hash, pixels) = Self.differenceHash(file.url),
                  hash != 0, hash != .max else { return } // flat images all hash alike
            entries.append(Entry(file: file, hash: hash, pixels: pixels))
        }
        try Task.checkCancellation()

        let groups = Self.cluster(entries.map(\.hash), maxDistance: maxDistance)
        let categories: [ScanCategory] = groups.map { indices in
            let members = indices.map { entries[$0] }
            let keep = members.max { ($0.pixels, $0.file.size) < ($1.pixels, $1.file.size) }!
            let items = members.map { entry in
                ScanItem(url: entry.file.url, size: entry.file.size, risk: .medium, autoSelect: false,
                         needsHelper: false,
                         detail: entry.file.url == keep.file.url ? "Migliore (risoluzione più alta)"
                                                                 : entry.file.url.deletingLastPathComponent().path)
            }
            return ScanCategory(id: "similar-\(keep.file.url.path)",
                                title: "\(keep.file.url.lastPathComponent) · \(members.count) simili",
                                items: items, keep: keep.file.url)
        }
        .sorted { $0.totalSize > $1.totalSize }
        return ScanReport(moduleID: id, categories: categories)
    }

    /// Groups hashes within `maxDistance` bits of each other (union-find).
    static func cluster(_ hashes: [UInt64], maxDistance: Int) -> [[Int]] {
        var parent = Array(hashes.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in hashes.indices {
            for j in (i + 1)..<hashes.count where (hashes[i] ^ hashes[j]).nonzeroBitCount <= maxDistance {
                parent[find(i)] = find(j)
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in hashes.indices { groups[find(i), default: []].append(i) }
        return groups.values.filter { $0.count > 1 }
    }

    static func differenceHash(_ url: URL) -> (UInt64, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        var gray = [UInt8](repeating: 0, count: 9 * 8)
        guard let context = CGContext(data: &gray, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(thumb, in: CGRect(x: 0, y: 0, width: 9, height: 8))

        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                hash <<= 1
                if gray[row * 9 + col] > gray[row * 9 + col + 1] { hash |= 1 }
            }
        }
        return (hash, width * height)
    }
}
