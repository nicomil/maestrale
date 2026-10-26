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
}
