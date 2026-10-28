import Foundation
import MaestraleCore
import MaestraleModules
import Testing
@testable import Maestrale

/// A temporary folder that is removed at the end of a test.
struct TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("maestrale-app-\(UUID().uuidString)")
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

    /// Uninstalling is about the bundle: it stays selected even when moving
    /// it takes the password (an app installed by root in /Applications).
    @Test func bundleIsPreselectedEvenWhenItNeedsThePassword() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let app = try await folder.app("Rooted", id: "com.test.rooted")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: app.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.url.path) }
        #expect(!app.isWritable)
        let model = UninstallerModel()
        model.findLeftovers = { _, _ in
            [ScanItem(url: URL(fileURLWithPath: "/tmp/system-leftover"), size: 1, risk: .low, autoSelect: true,
                      needsHelper: true, detail: "")]
        }
        await model.select(app)
        let bundle = try #require(model.files.first)
        #expect(bundle.needsHelper)
        #expect(model.fileSelection == [app.url]) // the other password item waits for the user
    }

    /// A bundle refused for permissions under /Applications is retried with the password.
    @Test func permissionFailuresAreRetriedAsAdmin() throws {
        let bundle = ScanItem(url: URL(fileURLWithPath: "/Applications/Rooted.app"), size: 5, risk: .medium,
                              autoSelect: true, needsHelper: false, detail: "Applicazione")
        let cache = ScanItem(url: URL(fileURLWithPath: "/Users/x/Library/Caches/com.test"), size: 1, risk: .low,
                             autoSelect: true, needsHelper: false, detail: "")
        let outcomes = [
            RemovalOutcome(url: bundle.url, result: .failure(.failed("permission"))),
            RemovalOutcome(url: cache.url, result: .failure(.failed("permission"))), // not a system folder
            RemovalOutcome(url: URL(fileURLWithPath: "/Applications/Other.app"), result: .failure(.outsideAllowedRoots)),
        ]
        #expect(UninstallerModel.retryableAsAdmin(outcomes, items: [bundle, cache]).map(\.url) == [bundle.url])
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

@MainActor
@Suite(.serialized) struct SelectionTests {
    func item(_ path: String, keep: Bool = false) -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: path), size: 1, risk: .low, autoSelect: false, needsHelper: false, detail: "")
    }

    /// "Seleziona tutto" follows the filter and never takes the copy that must stay.
    @Test func selectAllRespectsFilterAndKeptCopies() throws {
        let model = AppModel()
        let keep = item("/Users/x/Documents/a.pdf")
        let copy = item("/Users/x/Downloads/a.pdf")
        let other = item("/Users/x/Downloads/b.pdf")
        let report = ScanReport(moduleID: "duplicates", categories: [
            ScanCategory(id: "g", title: "a.pdf", items: [keep, copy], keep: keep.url),
            ScanCategory(id: "h", title: "b.pdf", items: [other]),
        ])
        model.modules["duplicates"]?.report = report
        model.selectAll(in: "duplicates")
        #expect(model.selection == [copy.url, other.url])
        model.deselectAll(in: "duplicates", matching: "b.pdf")
        #expect(model.selection == [copy.url])
        model.deselectAll(in: "duplicates")
        model.selectAll(in: "duplicates", matching: "Downloads/a")
        #expect(model.selection == [copy.url])
    }

    /// Emptying the Trash deletes: "move to the Trash" would be a no-op there.
    @Test func trashModuleAlwaysDeletes() {
        #expect(AppModel.effectiveMode(moduleID: TrashModule.id, chosen: .trash) == .delete)
        #expect(AppModel.effectiveMode(moduleID: TrashModule.id, chosen: .dryRun) == .dryRun)
        #expect(AppModel.effectiveMode(moduleID: SystemJunkModule.id, chosen: .trash) == .trash)
    }

    @Test func spaceLensSelectAllSkipsAggregates() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.file("tree/big.bin", bytes: 20_000_000)
        try folder.file("tree/small.txt", bytes: 10)
        let model = SpaceLensModel()
        model.scan(folder.url.appendingPathComponent("tree"))
        for _ in 0..<200 where model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
        let root = try #require(model.root)
        #expect(root.children.contains { $0.isAggregate })
        model.selectAll()
        #expect(model.selection.count == 1)
        #expect(model.selectedNodes().map(\.name) == ["big.bin"])
        model.deselectAll()
        #expect(model.selection.isEmpty)
    }
}

@Suite struct ProtectionFilterTests {
    func finding(_ title: String, _ severity: Finding.Severity, category: FindingCategory = .persistence,
                 isNew: Bool = false, path: String? = nil, reasons: [String] = ["motivo"]) -> Finding {
        var finding = Finding(category: category, key: title, severity: severity, title: title,
                              path: path.map { URL(fileURLWithPath: $0) }, reasons: reasons)
        finding.isNew = isNew
        return finding
    }

    @Test func protectionFilterNarrowsBySeverityAndText() {
        let all = [
            finding("Zeta agent", .warning, isNew: true, path: "/Users/x/Library/LaunchAgents/zeta.plist"),
            finding("Alpha daemon", .danger, category: .process),
            finding("Beta info", .info, reasons: ["firma mancante"]),
            finding("Gamma", .warning),
        ]
        let warnings = ProtectionModel.filter(all, minimum: .warning, onlyNew: false, search: "")
        // Dangers first, then the new one, then by title.
        #expect(warnings.map(\.title) == ["Alpha daemon", "Zeta agent", "Gamma"])
        #expect(ProtectionModel.filter(all, minimum: .danger, onlyNew: false, search: "").map(\.title) == ["Alpha daemon"])
        #expect(ProtectionModel.filter(all, minimum: .info, onlyNew: false, search: "").count == 4)
        #expect(ProtectionModel.filter(all, minimum: .info, onlyNew: true, search: "").map(\.title) == ["Zeta agent"])
        #expect(ProtectionModel.filter(all, minimum: .info, onlyNew: false, search: "firma").map(\.title) == ["Beta info"])
        #expect(ProtectionModel.filter(all, minimum: .info, onlyNew: false, search: "launchagents").map(\.title) == ["Zeta agent"])
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

@MainActor
struct ProgressCenterTests {
    @Test func operationDescribesCountsAndFraction() {
        var op = ProgressCenter.Operation(title: "Svuotamento del Cestino", total: 4, bytesTotal: 4_000_000)
        #expect(op.fraction == 0)
        op.completed = 1
        op.bytesDone = 1_000_000
        #expect(op.fraction == 0.25)
        #expect(op.counts?.hasPrefix("1 di 4 elementi · ") == true)
        let indeterminate = ProgressCenter.Operation(title: "Libera RAM")
        #expect(indeterminate.fraction == nil)
        #expect(indeterminate.counts == nil)
    }

    @Test func stopIsOnlyAcceptedWhenTheOperationAllowsIt() {
        let center = ProgressCenter.shared
        center.begin("Pulizia", total: 2, canStop: false)
        center.stop()
        #expect(!center.stopRequested)
        center.begin("Pulizia", total: 2, canStop: true)
        center.stop()
        #expect(center.stopRequested)
        #expect(!center.continuation()())
        center.end()
        #expect(center.current == nil)
    }
}

struct LegacyMigrationTests {
    @Test func foldersMoveOnceAndNeverOverwrite() throws {
        let home = try TempFolder()
        defer { home.remove() }
        let logs = home.url.appendingPathComponent("Library/Logs")
        try FileManager.default.createDirectory(at: logs.appendingPathComponent("MacCleaner"), withIntermediateDirectories: true)
        try "old".write(to: logs.appendingPathComponent("MacCleaner/operations.log"), atomically: true, encoding: .utf8)
        let defaults = UserDefaults(suiteName: "it.nico.maestrale.tests.\(UUID().uuidString)")!
        LegacyMigration.run(home: home.url, defaults: defaults)
        #expect(FileManager.default.fileExists(atPath: logs.appendingPathComponent("Maestrale/operations.log").path))
        #expect(!FileManager.default.fileExists(atPath: logs.appendingPathComponent("MacCleaner").path))
        // A second old folder appearing later never replaces the new one.
        try FileManager.default.createDirectory(at: logs.appendingPathComponent("MacCleaner"), withIntermediateDirectories: true)
        #expect(!LegacyMigration.moveIfNeeded(from: logs.appendingPathComponent("MacCleaner"), to: logs.appendingPathComponent("Maestrale")))
    }

    @Test func oldPreferencesAreCopiedWithoutOverwriting() {
        let suite = "it.nico.maestrale.tests.\(UUID().uuidString)"
        let oldDomain = "it.nico.maccleaner.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.setPersistentDomain(["largeFileMB": 500, "showMenuBar": false], forName: oldDomain)
        defaults.set(true, forKey: "showMenuBar")
        LegacyMigration.copyDefaultsIfNeeded(into: defaults, from: oldDomain)
        #expect(defaults.integer(forKey: "largeFileMB") == 500)
        #expect(defaults.bool(forKey: "showMenuBar") == true)
        defaults.removePersistentDomain(forName: oldDomain)
        defaults.removePersistentDomain(forName: suite)
    }
}
