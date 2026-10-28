import Foundation
import Testing
@testable import MacCleanerCore

/// A temporary folder with an "allowed" area and an "outside" area.
struct Sandbox {
    let base: URL
    let allowed: URL
    let outside: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccleaner-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        allowed = base.appendingPathComponent("allowed")
        outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ relative: String, in root: URL, bytes: Int = 4096) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: base) }
}

@Suite struct SafeRemoverTests {
    func remover(_ box: Sandbox, _ mode: RemovalMode) -> SafeRemover {
        SafeRemover(allowedRoots: [box.allowed], mode: mode, log: nil)
    }

    @Test func refusesPathOutsideAllowedRoots() throws {
        let box = try Sandbox(); defer { box.remove() }
        let target = try box.file("a.txt", in: box.outside)
        #expect(remover(box, .delete).validate(target) == .outsideAllowedRoots)
        _ = remover(box, .delete).remove([target])
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func refusesTheAllowedRootItself() throws {
        let box = try Sandbox(); defer { box.remove() }
        #expect(remover(box, .delete).validate(box.allowed) == .isAllowedRoot)
    }

    @Test func refusesDotDotEscape() throws {
        let box = try Sandbox(); defer { box.remove() }
        let target = try box.file("b.txt", in: box.outside)
        let sneaky = box.allowed.appendingPathComponent("../outside/b.txt")
        _ = remover(box, .delete).remove([sneaky])
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    /// "allowed/sub/.." and "allowed/." name the root itself, "allowed/.." the
    /// folder above it: none of them may pass, even with a trailing dot component.
    @Test func refusesDotComponentsAtTheEnd() throws {
        let box = try Sandbox(); defer { box.remove() }
        let sub = box.allowed.appendingPathComponent("sub")
        try box.file("sub/keep.txt", in: box.allowed)
        let r = remover(box, .delete)
        for sneaky in [sub.appendingPathComponent(".."), box.allowed.appendingPathComponent("."),
                       box.allowed.appendingPathComponent(".."), sub.appendingPathComponent(".")] {
            #expect(r.validate(sneaky) == .outsideAllowedRoots, "\(sneaky.path)")
        }
        _ = r.remove([sub.appendingPathComponent(".."), box.allowed.appendingPathComponent("..")])
        #expect(FileManager.default.fileExists(atPath: box.allowed.path))
        #expect(FileManager.default.fileExists(atPath: box.outside.path))
    }

    @Test func refusesFolderReachedThroughSymlinkedParent() throws {
        let box = try Sandbox(); defer { box.remove() }
        let secret = try box.file("dir/secret.txt", in: box.outside)
        let link = box.allowed.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: box.outside.appendingPathComponent("dir"))
        let viaLink = link.appendingPathComponent("secret.txt")
        #expect(remover(box, .delete).validate(viaLink) == .outsideAllowedRoots)
        _ = remover(box, .delete).remove([viaLink])
        #expect(FileManager.default.fileExists(atPath: secret.path))
    }

    @Test func removingASymlinkKeepsItsTarget() throws {
        let box = try Sandbox(); defer { box.remove() }
        let precious = try box.file("precious", in: box.outside)
        let link = box.allowed.appendingPathComponent("link-to-precious")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: precious)
        let outcome = remover(box, .delete).remove([link]).first
        #expect(outcome.map { (try? $0.result.get()) != nil } == true)
        #expect(FileManager.default.fileExists(atPath: precious.path))
        #expect((try? link.checkResourceIsReachable()) != true)
    }

    @Test func dryRunDoesNotRemove() throws {
        let box = try Sandbox(); defer { box.remove() }
        let target = try box.file("cache/data.bin", in: box.allowed, bytes: 10_000)
        let outcome = try #require(remover(box, .dryRun).remove([target]).first)
        #expect(try outcome.result.get() > 0)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func deleteRemovesInsideAllowedRoot() throws {
        let box = try Sandbox(); defer { box.remove() }
        let folder = box.allowed.appendingPathComponent("cache")
        try box.file("cache/x/y.bin", in: box.allowed)
        _ = remover(box, .delete).remove([folder])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func systemFoldersAreProtected() {
        #expect(SafeRemover.isSystemProtected(URL(fileURLWithPath: "/System/Library/CoreServices")))
        #expect(SafeRemover.isSystemProtected(URL(fileURLWithPath: "/usr/bin/true")))
        #expect(!SafeRemover.isSystemProtected(URL(fileURLWithPath: "/usr/local/bin")))
    }

    @Test func operationsAreLogged() throws {
        let box = try Sandbox(); defer { box.remove() }
        let logURL = box.base.appendingPathComponent("ops.log")
        let log = OperationLog(fileURL: logURL)
        let target = try box.file("z.bin", in: box.allowed)
        _ = SafeRemover(allowedRoots: [box.allowed], mode: .dryRun, log: log).remove([target])
        log.flush()
        let text = try String(contentsOf: logURL, encoding: .utf8)
        #expect(text.contains("dryRun\tok"))
        #expect(text.contains(target.lastPathComponent))
    }

    func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
    }

    /// A locked file in the Trash is what keeps it from emptying: with
    /// `unlocksItems` the flag is cleared and the file goes.
    @Test func deleteUnlocksLockedFilesWhenAsked() throws {
        let box = try Sandbox(); defer { box.remove() }
        let folder = box.allowed.appendingPathComponent("locked folder")
        let inner = try box.file("locked folder/inner.txt", in: box.allowed)
        try lock(inner)
        try lock(folder)
        let single = try box.file("single.txt", in: box.allowed)
        try lock(single)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: single.path) }

        let remover = SafeRemover(allowedRoots: [box.allowed], mode: .delete, log: nil, unlocksItems: true)
        let outcomes = remover.remove([folder, single])
        #expect(outcomes.allSatisfy { (try? $0.result.get()) != nil })
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!FileManager.default.fileExists(atPath: single.path))
    }

    /// Everywhere else a locked file stays locked and is reported as not removed.
    @Test func deleteLeavesLockedFilesAloneByDefault() throws {
        let box = try Sandbox(); defer { box.remove() }
        let single = try box.file("single.txt", in: box.allowed)
        try lock(single)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: single.path) }
        let outcome = try #require(remover(box, .delete).remove([single]).first)
        #expect((try? outcome.result.get()) == nil)
        #expect(FileManager.default.fileExists(atPath: single.path))
    }

    /// Progress is reported before the first item and after each one, with the bytes freed so far.
    @Test func progressReportsEveryItem() throws {
        let box = try Sandbox(); defer { box.remove() }
        let a = try box.file("a.txt", in: box.allowed)
        let b = try box.file("b.txt", in: box.allowed)
        final class Seen: @unchecked Sendable { var steps: [(Int, Int, URL?)] = [] }
        let seen = Seen()
        let outcomes = remover(box, .delete).remove([a, b]) { seen.steps.append(($0.completed, $0.total, $0.next)) }
        #expect(outcomes.count == 2)
        #expect(seen.steps.map(\.0) == [0, 1, 2])
        #expect(seen.steps.map(\.1) == [2, 2, 2])
        #expect(seen.steps.map(\.2) == [a, b, nil])
    }

    /// Stopping leaves the remaining items untouched and out of the outcomes.
    @Test func removalStopsWhenAsked() throws {
        let box = try Sandbox(); defer { box.remove() }
        let a = try box.file("a.txt", in: box.allowed)
        let b = try box.file("b.txt", in: box.allowed)
        final class Flag: @unchecked Sendable { var goOn = true }
        let flag = Flag()
        let outcomes = remover(box, .delete).remove([a, b], progress: { if $0.completed == 1 { flag.goOn = false } },
                                                    shouldContinue: { flag.goOn })
        #expect(outcomes.count == 1)
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
    }

    /// Unlocking never reaches outside the allowed folders: the check comes first.
    @Test func unlockingDoesNotTouchItemsOutsideAllowedRoots() throws {
        let box = try Sandbox(); defer { box.remove() }
        let outside = try box.file("outside.txt", in: box.outside)
        try lock(outside)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: outside.path) }
        let remover = SafeRemover(allowedRoots: [box.allowed], mode: .delete, log: nil, unlocksItems: true)
        let outcome = try #require(remover.remove([outside]).first)
        #expect(outcome.result == .failure(.outsideAllowedRoots))
        var info = stat()
        #expect(lstat(outside.path, &info) == 0 && info.st_flags & UInt32(UF_IMMUTABLE) != 0)
    }
}
