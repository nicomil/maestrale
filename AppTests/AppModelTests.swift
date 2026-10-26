import Foundation
import MacCleanerCore
import MacCleanerModules
import Testing
@testable import MacCleaner

/// A temporary folder that is removed at the end of a test.
struct TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("maccleaner-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 10_000, fill: UInt8 = 1) throws -> URL {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: target)
        return target
    }

    /// A minimal app bundle, read back as `InstalledApp`.
    func app(_ name: String, id: String) async throws -> InstalledApp {
        let contents = url.appendingPathComponent("Applications/\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleName": name]
        info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        let apps = await AppInventory(home: url, folders: [url.appendingPathComponent("Applications")]).load()
        return try #require(apps.first { $0.bundleID == id })
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

@MainActor
@Suite(.serialized) struct UninstallerModelTests {
    func leftover(_ name: String) -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: "/tmp/\(name)"), size: 1, risk: .low, autoSelect: true,
                 needsHelper: false, detail: "")
    }

    /// The search for app A is slow; meanwhile the user picks app B. A's
    /// results arrive late and must not show up under B.
    @Test func lateResultsOfThePreviousAppAreDropped() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let slow = try await folder.app("Slow", id: "com.test.slow")
        let fast = try await folder.app("Fast", id: "com.test.fast")
        let model = UninstallerModel()
        model.findLeftovers = { app, _ in
            if app.bundleID == "com.test.slow" { Thread.sleep(forTimeInterval: 0.4) }
            return [ScanItem(url: URL(fileURLWithPath: "/tmp/leftover-of-\(app.bundleID)"), size: 1, risk: .low,
                             autoSelect: true, needsHelper: false, detail: "")]
        }

        let first = Task { await model.select(slow) }
        while model.selectedApp?.bundleID != "com.test.slow" { await Task.yield() }
        await model.select(fast)
        await first.value

        #expect(model.selectedApp?.bundleID == "com.test.fast")
        let names = model.files.map(\.url.lastPathComponent)
        #expect(names.contains("leftover-of-com.test.fast"))
        #expect(!names.contains("leftover-of-com.test.slow"))
        #expect(model.fileSelection.allSatisfy { $0.lastPathComponent != "leftover-of-com.test.slow" })
    }

    /// While files are being removed, picking another app does nothing.
    @Test func selectionIsLockedWhileWorking() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let first = try await folder.app("First", id: "com.test.first")
        let second = try await folder.app("Second", id: "com.test.second")
        let model = UninstallerModel()
        model.findLeftovers = { _, _ in [] }
        await model.select(first)
        model.isWorking = true
        await model.select(second)
        #expect(model.selectedApp?.bundleID == "com.test.first")
        #expect(model.files.map(\.url) == [first.url])
    }
}

@MainActor
@Suite(.serialized) struct SpaceLensModelTests {
    func waitUntilDone(_ model: SpaceLensModel) async throws {
        for _ in 0..<200 where model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isScanning)
    }

    /// A second scan replaces the first: only its result is shown, even after
    /// the first one would have finished.
    @Test func onlyTheLatestScanIsShown() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        for index in 0..<300 { try folder.file("first/dir\(index % 30)/file\(index)") }
        try folder.file("second/only.bin")
        let model = SpaceLensModel()
        model.scan(folder.url.appendingPathComponent("first"))
        model.scan(folder.url.appendingPathComponent("second"))
        try await waitUntilDone(model)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.root?.name == "second")
    }

    @Test func cancelLeavesNoResultAndStopsScanning() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        for index in 0..<300 { try folder.file("tree/dir\(index % 30)/file\(index)") }
        let model = SpaceLensModel()
        model.scan(folder.url.appendingPathComponent("tree"))
        model.cancel()
        #expect(!model.isScanning)
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.root == nil)
        #expect(!model.isScanning)
    }
}

@Suite struct CopyGroupTests {
    /// A group of copies is skipped when the copy that stays has changed or gone.
    @Test func changedGroupsAreSkipped() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let keep = try folder.file("Documents/a.pdf", bytes: 50_000, fill: 3)
        let copy = try folder.file("Downloads/a.pdf", bytes: 50_000, fill: 3)
        let item = { (url: URL) in
            ScanItem(url: url, size: 50_000, risk: .low, autoSelect: true, needsHelper: false, detail: "")
        }
        let report = ScanReport(moduleID: "duplicates", categories: [
            ScanCategory(id: "g", title: "a.pdf", items: [item(keep), item(copy)], keep: keep),
        ])
        #expect(AppModel.changedCopyGroups(report, selected: [copy], identical: true).groups == 0)

        try Data(repeating: 4, count: 50_000).write(to: keep)
        let changed = AppModel.changedCopyGroups(report, selected: [copy], identical: true)
        #expect(changed.groups == 1 && changed.urls == [copy])

        try FileManager.default.removeItem(at: keep)
        #expect(AppModel.changedCopyGroups(report, selected: [copy], identical: false).groups == 1)
    }
}
