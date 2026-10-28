import Foundation

/// Computes the space a file or folder really takes on disk.
public enum FileSizer {
    private static let keys: [URLResourceKey] = [
        .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]

    /// Allocated size in bytes. Symlinks are not followed, so a link to a big
    /// folder counts as almost nothing, as it should.
    public static func allocatedSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                       .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        if values?.isSymbolicLink == true { return 0 }
        guard values?.isDirectory == true else {
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let v = try? child.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }
}
