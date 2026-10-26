import Darwin
import Foundation
import Testing
@testable import MacCleanerCore

/// The privileged helper's logic, run as the current user on temporary folders.
@Suite struct AdminHelperTests {
    /// Canonical path, as the helper expects it ("/private/var/…", not "/var/…").
    func real(_ url: URL) throws -> String {
        let resolved = try #require(realpath(url.path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func run(_ arguments: [String], roots: [String]) -> AdminHelper.Result {
        AdminHelper.run(arguments, roots: roots)
    }

    /// The folder is swapped for a symlink after the app checked it: the
    /// helper refuses instead of deleting the file it now points to.
    @Test func swappedFolderIsRefused() throws {
        let box = try Sandbox(); defer { box.remove() }
        let root = try real(box.allowed)
        let vendor = box.allowed.appendingPathComponent("vendor")
        try box.file("vendor/junk", in: box.allowed)
        let precious = try box.file("dir/junk", in: box.outside)
        try FileManager.default.moveItem(at: vendor, to: box.allowed.appendingPathComponent("vendor-old"))
        try FileManager.default.createSymbolicLink(at: vendor, withDestinationURL: box.outside.appendingPathComponent("dir"))

        let result = run(["remove", root + "/vendor", "junk"], roots: [root])
        #expect(result.lines.count == 1 && result.lines[0].hasPrefix("err\t"))
        #expect(FileManager.default.fileExists(atPath: precious.path))
    }

    @Test func removingAFolderNeverFollowsSymlinksInside() throws {
        let box = try Sandbox(); defer { box.remove() }
        let root = try real(box.allowed)
        let precious = try box.file("keep/precious", in: box.outside)
        try box.file("cache/deep/file", in: box.allowed)
        try FileManager.default.createSymbolicLink(at: box.allowed.appendingPathComponent("cache/deep/link"),
                                                   withDestinationURL: box.outside.appendingPathComponent("keep"))

        let result = run(["remove", root, "cache"], roots: [root])
        #expect(result.lines == ["ok\t\(root)/cache"])
        #expect(!FileManager.default.fileExists(atPath: box.allowed.appendingPathComponent("cache").path))
        #expect(FileManager.default.fileExists(atPath: precious.path))
    }

    @Test func trashKeepsExistingItemsAndChecksTheOwner() throws {
        let box = try Sandbox(); defer { box.remove() }
        let root = try real(box.allowed)
        let trash = box.base.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: trash.appendingPathComponent("a.log").path, contents: Data("old".utf8))
        try box.file("logs/a.log", in: box.allowed)
        let trashPath = try real(trash)

        let result = run(["trash", trashPath, String(getuid()), root + "/logs", "a.log"], roots: [root])
        #expect(result.lines == ["ok\t\(root)/logs/a.log\t\(trashPath)/a 2.log"])
        #expect(try String(contentsOf: trash.appendingPathComponent("a.log"), encoding: .utf8) == "old")
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("a 2.log").path))

        // A Trash owned by someone else, or reached through a symlink, is refused.
        try box.file("logs/b.log", in: box.allowed)
        #expect(run(["trash", trashPath, "0", root + "/logs", "b.log"], roots: [root]).status == 1)
        let link = box.base.appendingPathComponent("TrashLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: trash)
        #expect(run(["trash", link.path, String(getuid()), root + "/logs", "b.log"], roots: [root]).status == 1)
        #expect(FileManager.default.fileExists(atPath: box.allowed.appendingPathComponent("logs/b.log").path))
    }

    @Test func onlyPlainItemsInsideTheRootsAreAccepted() throws {
        let box = try Sandbox(); defer { box.remove() }
        let root = try real(box.allowed)
        let outside = try real(box.outside)
        try box.file("x", in: box.outside)
        try box.file("sub/y", in: box.allowed)
        for arguments in [["remove", outside, "x"],                  // outside
                          ["remove", try real(box.base), "allowed"], // the root itself
                          ["remove", root + "/sub", ".."],
                          ["remove", root + "/sub/..", "sub"],
                          ["remove", root + "//sub", "y"]] {
            let result = run(arguments, roots: [root])
            #expect(result.lines.allSatisfy { $0.hasPrefix("err\t") }, "\(arguments)")
        }
        #expect(FileManager.default.fileExists(atPath: box.outside.appendingPathComponent("x").path))
        #expect(FileManager.default.fileExists(atPath: box.allowed.appendingPathComponent("sub/y").path))
        #expect(run(["remove", root], roots: [root]).status == 2)
        #expect(run(["format"], roots: [root]).status == 2)
    }

    @Test func numberedNames() {
        #expect(PinnedFileSystem.numberedName("a.log", 1) == "a.log")
        #expect(PinnedFileSystem.numberedName("a.log", 3) == "a 3.log")
        #expect(PinnedFileSystem.numberedName("dir", 2) == "dir 2")
        #expect(PinnedFileSystem.numberedName(".hidden", 2) == ".hidden 2")
    }
}
