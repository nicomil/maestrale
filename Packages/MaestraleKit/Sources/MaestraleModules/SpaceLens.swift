import Foundation
import MaestraleCore

/// One file or folder in the Space Lens map.
public final class DiskNode: Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let size: Int64
    public let isDirectory: Bool
    /// True for the node that groups the small files of a folder.
    public let isAggregate: Bool
    public let fileCount: Int
    /// Sorted by size, biggest first.
    public let children: [DiskNode]

    public var id: URL { url }

    init(url: URL, name: String? = nil, size: Int64, isDirectory: Bool, isAggregate: Bool = false,
         fileCount: Int, children: [DiskNode] = []) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.size = size
        self.isDirectory = isDirectory
        self.isAggregate = isAggregate
        self.fileCount = fileCount
        self.children = children.sorted { $0.size > $1.size }
    }
}

/// Counts scanned files from many threads, for the progress label.
public final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var bytes: Int64 = 0

    public init() {}

    func add(files count: Int, bytes size: Int64) {
        lock.lock(); files += count; bytes += size; lock.unlock()
    }

    public var snapshot: (files: Int, bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        return (files, bytes)
    }
}

/// Builds the size map of a folder.
///
/// Packages (apps, libraries) are shown as one block. Files smaller than
/// `minimumFileSize` are merged into an "other files" block per folder so the
/// tree stays small. Firmlinked system paths are skipped to avoid counting the
/// Data volume twice when scanning "/".
public struct SpaceLensScanner: Sendable {
    public var minimumFileSize: Int64
    public var parallelDepth: Int

    public init(minimumFileSize: Int64 = 10_000_000, parallelDepth: Int = 2) {
        self.minimumFileSize = minimumFileSize
        self.parallelDepth = parallelDepth
    }

    static let skippedPaths: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm", "/cores"]
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    public func scan(_ root: URL, counter: ScanCounter = ScanCounter()) async -> DiskNode {
        await scanDirectory(root, depth: 0, counter: counter)
    }

    private func scanDirectory(_ url: URL, depth: Int, counter: ScanCounter) async -> DiskNode {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Self.keys, options: [])) ?? []

        var nodes: [DiskNode] = []
        var subfolders: [URL] = []
        var smallSize: Int64 = 0
        var smallCount = 0

        for entry in entries {
            if Task.isCancelled { break }
            if Self.skippedPaths.contains(entry.path) { continue }
            guard let v = try? entry.resourceValues(forKeys: Set(Self.keys)), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true && v.isPackage != true {
                subfolders.append(entry)
                continue
            }
            let size: Int64 = v.isPackage == true
                ? FileSizer.allocatedSize(of: entry)
                : Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            counter.add(files: 1, bytes: size)
            if size >= minimumFileSize || v.isPackage == true {
                nodes.append(DiskNode(url: entry, size: size, isDirectory: false, fileCount: 1))
            } else {
                smallSize += size
                smallCount += 1
            }
        }

        if depth < parallelDepth {
            await withTaskGroup(of: DiskNode.self) { group in
                for folder in subfolders {
                    group.addTask { await scanDirectory(folder, depth: depth + 1, counter: counter) }
                }
                for await node in group { nodes.append(node) }
            }
        } else {
            for folder in subfolders {
                nodes.append(await scanDirectory(folder, depth: depth + 1, counter: counter))
            }
        }

        if smallCount > 0 {
            nodes.append(DiskNode(url: url.appendingPathComponent(".maestrale-other-files"),
                                  name: "\(smallCount) file piccoli", size: smallSize, isDirectory: false,
                                  isAggregate: true, fileCount: smallCount))
        }
        nodes.removeAll { $0.size == 0 }
        return DiskNode(url: url, size: nodes.reduce(0) { $0 + $1.size }, isDirectory: true,
                        fileCount: nodes.reduce(0) { $0 + $1.fileCount }, children: nodes)
    }
}

/// Squarified treemap layout (Bruls, Huizing, van Wijk): splits a rectangle
/// into tiles whose areas are proportional to the values, keeping tiles as
/// close to squares as possible.
public enum Treemap {
    public static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let scale = rect.width * rect.height / total
        let areas = values.map { $0 * scale }
        var result = [CGRect](repeating: .zero, count: values.count)
        var remaining = rect
        var start = 0

        while start < areas.count {
            let side = min(remaining.width, remaining.height)
            var end = start + 1
            var best = worstRatio(areas[start..<end], side: side)
            while end < areas.count {
                let next = worstRatio(areas[start...end], side: side)
                if next > best { break }
                best = next
                end += 1
            }
            let rowArea = areas[start..<end].reduce(0, +)
            if remaining.width >= remaining.height {
                let width = rowArea / remaining.height
                var y = remaining.minY
                for i in start..<end {
                    let height = areas[i] / width
                    result[i] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                                   width: max(0, remaining.width - width), height: remaining.height)
            } else {
                let height = rowArea / remaining.width
                var x = remaining.minX
                for i in start..<end {
                    let width = areas[i] / height
                    result[i] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                                   width: remaining.width, height: max(0, remaining.height - height))
            }
            start = end
        }
        return result
    }

    static func worstRatio(_ row: ArraySlice<Double>, side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0, let maxArea = row.max(), let minArea = row.min(), minArea > 0 else {
            return .infinity
        }
        let s2 = side * side, sum2 = sum * sum
        return max(s2 * maxArea / sum2, sum2 / (s2 * minArea))
    }
}
