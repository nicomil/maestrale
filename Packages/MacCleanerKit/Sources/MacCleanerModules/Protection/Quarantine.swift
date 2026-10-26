import Darwin
import Foundation
import MacCleanerCore

/// One item put aside by the user: where it was, why, and where it is now.
public struct QuarantineRecord: Codable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let title: String
    public let originalPath: String
    public let reasons: [String]
    public let date: Date
    /// The folder holding the item (and nothing else) inside the quarantine.
    public let storedFolder: String
    public let storedName: String
    /// True when the item was moved by the privileged helper and lives in the
    /// system quarantine, so restoring or deleting it needs the password.
    public let isSystem: Bool

    public var storedPath: String { storedFolder + "/" + storedName }

    public init(id: UUID, title: String, originalPath: String, reasons: [String], date: Date, storedFolder: String,
                storedName: String, isSystem: Bool) {
        self.id = id
        self.title = title
        self.originalPath = originalPath
        self.reasons = reasons
        self.date = date
        self.storedFolder = storedFolder
        self.storedName = storedName
        self.isSystem = isSystem
    }
}

/// Where dangerous items go instead of the Trash: a folder of the app, one
/// sub-folder per item, permissions removed so nothing in it can run. The
/// index keeps what the user needs to put things back.
public struct Quarantine: Sendable {
    public let folder: URL
    public static let userFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacCleaner/Quarantine")
    public static let systemFolder = "/Library/Application Support/MacCleaner/Quarantine"
    private let log: OperationLog?

    public init(folder: URL = Quarantine.userFolder, log: OperationLog? = .standard) {
        self.folder = folder
        self.log = log
    }

    var index: URL { folder.appendingPathComponent("index.json") }

    public func records() -> [QuarantineRecord] {
        guard let data = try? Data(contentsOf: index),
              let records = try? JSONDecoder().decode([QuarantineRecord].self, from: data) else { return [] }
        return records.sorted { $0.date > $1.date }
    }

    func save(_ records: [QuarantineRecord]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(records)
        try data.write(to: index, options: .atomic)
    }

    public func add(_ record: QuarantineRecord) throws {
        try save(records().filter { $0.id != record.id } + [record])
    }

    public func forget(_ record: QuarantineRecord) throws {
        try save(records().filter { $0.id != record.id })
    }

    /// Moves one of the user's files into the quarantine. The parent folder is
    /// opened without following symlinks and the move is relative to it, like
    /// the privileged helper does; the item is then stripped of every permission.
    @discardableResult
    public func quarantine(_ url: URL, title: String, reasons: [String], allowedRoots: [URL]) throws -> QuarantineRecord {
        let validator = SafeRemover(allowedRoots: allowedRoots, mode: .dryRun, log: nil)
        if let error = validator.validate(url) { throw PinnedFileError("\(url.path): \(error)") }
        guard PinnedFileSystem.isPlainName(url.lastPathComponent) else { throw PinnedFileError("\(url.path): nome non valido") }
        guard let parent = realpath(url.deletingLastPathComponent().path, nil).map({ String(cString: $0) }) else {
            throw PinnedFileError("\(url.path): cartella non trovata")
        }
        let id = UUID()
        let created = folder.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Canonical paths, as PinnedFileSystem expects ("/private/var/…").
        guard let destination = realpath(created.path, nil).map({ String(cString: $0) }) else {
            throw PinnedFileError("\(created.path): cartella di quarantena non trovata")
        }
        let source = try PinnedFileSystem.openDirectory(parent)
        defer { close(source) }
        let target = try PinnedFileSystem.openDirectory(destination)
        defer { close(target) }
        let used = try PinnedFileSystem.moveEntry(from: source, named: url.lastPathComponent, into: target)
        Self.lock(URL(fileURLWithPath: destination + "/" + used))
        let record = QuarantineRecord(id: id, title: title, originalPath: parent + "/" + url.lastPathComponent, reasons: reasons,
                                      date: Date(), storedFolder: destination, storedName: used, isSystem: false)
        try add(record)
        log?.recordAdmin("Quarantena di \(url.path)", ok: true, detail: record.storedPath)
        return record
    }

    /// Puts a user item back where it was. Fails if something is there now.
    public func restore(_ record: QuarantineRecord) throws {
        guard !record.isSystem else { throw PinnedFileError("elemento di sistema: serve la password") }
        let original = URL(fileURLWithPath: record.originalPath)
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let parent = realpath(original.deletingLastPathComponent().path, nil).map({ String(cString: $0) }) else {
            throw PinnedFileError("\(record.originalPath): cartella non trovata")
        }
        Self.unlock(URL(fileURLWithPath: record.storedPath))
        let source = try PinnedFileSystem.openDirectory(record.storedFolder)
        defer { close(source) }
        let target = try PinnedFileSystem.openDirectory(parent)
        defer { close(target) }
        guard faccessat(target, original.lastPathComponent, F_OK, AT_SYMLINK_NOFOLLOW) != 0 else {
            throw PinnedFileError("\(record.originalPath): esiste già qualcosa con questo nome")
        }
        _ = try PinnedFileSystem.moveEntry(from: source, named: record.storedName, into: target)
        try? FileManager.default.removeItem(atPath: record.storedFolder)
        try forget(record)
        log?.recordAdmin("Ripristino di \(record.originalPath)", ok: true, detail: record.storedPath)
    }

    /// Deletes a user item for good.
    public func delete(_ record: QuarantineRecord) throws {
        guard !record.isSystem else { throw PinnedFileError("elemento di sistema: serve la password") }
        Self.unlock(URL(fileURLWithPath: record.storedPath))
        try FileManager.default.removeItem(atPath: record.storedFolder)
        try forget(record)
        log?.recordAdmin("Eliminazione dalla quarantena di \(record.originalPath)", ok: true, detail: record.storedPath)
    }

    /// Removes every permission, recursively, and marks the item as quarantined
    /// so Gatekeeper would stop it even if it were copied out.
    static func lock(_ url: URL) {
        let mark = "0083;00000000;MacCleaner;"
        setxattr(url.path, "com.apple.quarantine", mark, mark.utf8.count, 0, XATTR_NOFOLLOW)
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.producesRelativePathURLs]) {
            var inner: [URL] = []
            for case let item as URL in enumerator { inner.append(item) }
            for item in inner.reversed() { lchmod(item.path, 0) }
        }
        lchmod(url.path, 0)
    }

    static func unlock(_ url: URL) {
        lchmod(url.path, 0o700)
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in enumerator { lchmod(item.path, 0o700) }
        }
    }
}
