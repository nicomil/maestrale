import Foundation
import MacCleanerCore
import MacCleanerModules
import Observation

/// Where the sidebar can take the user.
enum Destination: Hashable {
    case smartCare
    case module(String)
    case spaceLens
    case uninstaller
    case updates
    case privacy
    case performance
    case protection
}

/// A sidebar group.
struct SidebarSection: Identifiable {
    let title: String
    let entries: [SidebarEntry]
    var id: String { title }
}

struct SidebarEntry: Identifiable, Hashable {
    let destination: Destination
    let title: String
    let icon: String
    var id: Destination { destination }
}

/// State shared by the whole window: scan results, selection and cleaning.
@MainActor
@Observable
final class AppModel {
    struct ModuleState: Identifiable {
        let module: any CleanerModule
        let icon: String
        var report: ScanReport?
        var isScanning = false
        var error: String?
        var lastCleanSummary: String?
        var id: String { module.id }
    }

    var modules: [String: ModuleState] = [:]
    var selection: Set<URL> = []
    var removalMode: RemovalMode = .trash
    var isCleaning = false
    let spaceLens = SpaceLensModel()
    let uninstaller = UninstallerModel()
    let updates = UpdatesModel()
    let privacy = PrivacyModel()
    let performance = PerformanceModel()
    let protection = ProtectionModel()
    let smartCare = SmartCareModel()
    private let scheduler = Scheduler()
    private(set) var sections: [SidebarSection] = []

    init() {
        func add(_ module: any CleanerModule, icon: String) -> SidebarEntry {
            modules[module.id] = ModuleState(module: module, icon: icon)
            return SidebarEntry(destination: .module(module.id), title: module.title, icon: icon)
        }
        var cleanup: [SidebarEntry] = []
        if let junk = try? SystemJunkModule() { cleanup.append(add(junk, icon: "internaldrive")) }
        cleanup.append(add(TrashModule(), icon: "trash"))
        cleanup.append(add(MailAttachmentsModule(), icon: "paperclip"))
        cleanup.append(add(InstallersModule(), icon: "shippingbox"))

        let space: [SidebarEntry] = [
            SidebarEntry(destination: .spaceLens, title: "Space Lens", icon: "circle.hexagongrid"),
            add(LargeOldFilesModule(minimumSize: Self.largeFileThreshold), icon: "doc.badge.clock"),
            add(DuplicatesModule(), icon: "doc.on.doc"),
            add(SimilarImagesModule(), icon: "photo.on.rectangle"),
        ]
        let applications: [SidebarEntry] = [
            SidebarEntry(destination: .uninstaller, title: "Disinstallazione", icon: "xmark.app"),
            SidebarEntry(destination: .updates, title: "Aggiornamenti", icon: "arrow.down.app"),
            add(OrphanLeftoversModule(), icon: "puzzlepiece.extension"),
        ]
        removalMode = RemovalMode(rawValue: UserDefaults.standard.string(forKey: "defaultRemovalMode") ?? "") ?? .trash
        sections = [
            SidebarSection(title: "", entries: [
                SidebarEntry(destination: .smartCare, title: "Smart Care", icon: "sparkles"),
            ]),
            SidebarSection(title: "Pulizia", entries: cleanup),
            SidebarSection(title: "Spazio", entries: space),
            SidebarSection(title: "Applicazioni", entries: applications),
            SidebarSection(title: "Protezione e velocità", entries: [
                SidebarEntry(destination: .protection, title: "Protezione", icon: "shield.lefthalf.filled"),
                SidebarEntry(destination: .privacy, title: "Privacy", icon: "hand.raised"),
                SidebarEntry(destination: .performance, title: "Prestazioni", icon: "gauge.with.dots.needle.67percent"),
            ]),
        ]
    }

    static var largeFileThreshold: Int64 {
        let mb = UserDefaults.standard.integer(forKey: "largeFileMB")
        return Int64(mb > 0 ? mb : 50) * 1_000_000
    }

    func setLargeFileThreshold(megabytes: Int) {
        guard let icon = modules["large-old-files"]?.icon else { return }
        modules["large-old-files"] = ModuleState(module: LargeOldFilesModule(minimumSize: Int64(megabytes) * 1_000_000),
                                                 icon: icon)
    }

    func startScheduler() {
        scheduler.start(self)
    }

    func scan(_ id: String) async {
        guard let module = modules[id]?.module else { return }
        modules[id]?.isScanning = true
        modules[id]?.error = nil
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Scansione")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        do {
            let report = try await Task.detached(priority: .userInitiated) { try await module.scan() }.value
            modules[id]?.report = report
            // Preselect only what the module marks as safe and what we can remove ourselves.
            selection.subtract(report.allItems.map(\.url))
            selection.formUnion(report.allItems.filter { $0.autoSelect && !$0.needsHelper }.map(\.url))
            // Items needing the password stay unselected until the user picks them.
        } catch {
            modules[id]?.error = error.localizedDescription
        }
        modules[id]?.isScanning = false
    }

    func selectedItems(in id: String) -> [ScanItem] {
        guard let report = modules[id]?.report else { return [] }
        return report.allItems.filter { selection.contains($0.url) }
    }

    func selectedSize(in id: String) -> Int64 {
        selectedItems(in: id).reduce(0) { $0 + $1.size }
    }

    /// Groups of copies where every item is selected: cleaning them would
    /// leave no copy at all, so the clean is blocked until one is unselected.
    func fullySelectedCopyGroups(in id: String) -> [ScanCategory] {
        guard let report = modules[id]?.report else { return [] }
        return report.categories.filter { category in
            category.keep != nil && category.items.allSatisfy { selection.contains($0.url) }
        }
    }

    func setCategory(_ category: ScanCategory, selected: Bool) {
        let urls = category.items.filter { $0.url != category.keep }.map(\.url)
        if selected { selection.formUnion(urls) } else { selection.subtract(category.items.map(\.url)) }
    }

    func clean(_ id: String) async {
        guard let module = modules[id]?.module, fullySelectedCopyGroups(in: id).isEmpty else { return }
        let items = selectedItems(in: id)
        guard !items.isEmpty else { return }
        isCleaning = true
        let mode = removalMode
        let remover = SafeRemover(allowedRoots: module.allowedRoots, mode: mode)
        let userItems = items.filter { !$0.needsHelper }
        let adminItems = items.filter(\.needsHelper)
        var outcomes = await Task.detached { remover.remove(userItems.map(\.url)) }.value
        var adminNote = ""
        if !adminItems.isEmpty {
            let result = await Self.removeAsAdmin(adminItems, dryRun: mode == .dryRun)
            outcomes += result.outcomes
            adminNote = result.note
        }
        modules[id]?.lastCleanSummary = Self.summary(outcomes, mode: mode) + adminNote
        isCleaning = false
        if mode != .dryRun { await scan(id) }
    }

    /// Removes system items with one administrator password prompt.
    /// They are deleted (not trashed): only caches and logs that the system recreates qualify.
    static func removeAsAdmin(_ items: [ScanItem], dryRun: Bool) async -> (outcomes: [RemovalOutcome], note: String) {
        let urls = items.map(\.url)
        let runner = AdminRunner()
        do {
            if dryRun {
                _ = try runner.command(for: .remove(urls))
            } else {
                try await Task.detached { try runner.run(.remove(urls)) }.value
            }
            return (items.map { RemovalOutcome(url: $0.url, result: .success($0.size)) }, "")
        } catch AdminError.cancelled {
            return ([], " · password annullata, elementi di sistema non rimossi")
        } catch {
            return ([], " · elementi di sistema non rimossi: \(error)")
        }
    }

    static func summary(_ outcomes: [RemovalOutcome], mode: RemovalMode) -> String {
        let freed = outcomes.reduce(Int64(0)) { $0 + ((try? $1.result.get()) ?? 0) }
        let refused = outcomes.filter { (try? $0.result.get()) == nil }.count
        let verb = mode == .dryRun ? "Si libererebbero" : "Liberati"
        return "\(verb) \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))"
            + (refused > 0 ? " · \(refused) non rimossi (vedi log)" : "")
    }
}

/// State of the Space Lens map.
@MainActor
@Observable
final class SpaceLensModel {
    var root: DiskNode?
    /// Folders the user has opened, from the root down.
    var path: [DiskNode] = []
    var isScanning = false
    var scannedFiles = 0
    var scannedBytes: Int64 = 0
    var selection: Set<URL> = []
    var lastCleanSummary: String?
    private var scanTask: Task<Void, Never>?

    var current: DiskNode? { path.last ?? root }

    var allowedRoots: [URL] { AllowedRoots.userFiles() + AllowedRoots.user() }

    func scan(_ url: URL) {
        scanTask?.cancel()
        isScanning = true
        root = nil
        path = []
        selection = []
        let counter = ScanCounter()
        scanTask = Task {
            // Keeps App Nap from throttling the scan and the progress label
            // while the window is in the background.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Space Lens")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let progress = Task {
                while !Task.isCancelled {
                    let snap = counter.snapshot
                    scannedFiles = snap.files
                    scannedBytes = snap.bytes
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            let node = await Task.detached(priority: .userInitiated) {
                await SpaceLensScanner().scan(url, counter: counter)
            }.value
            progress.cancel()
            if !Task.isCancelled { root = node }
            isScanning = false
        }
    }

    func cancel() {
        scanTask?.cancel()
        isScanning = false
    }

    func open(_ node: DiskNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        path.append(node)
    }

    func goUp(to index: Int?) {
        if let index { path = Array(path.prefix(index + 1)) } else { path = [] }
    }

    func selectedNodes() -> [DiskNode] {
        guard let current else { return [] }
        return current.children.filter { selection.contains($0.url) && !$0.isAggregate }
    }

    func trashSelected(mode: RemovalMode) async {
        let urls = selectedNodes().map(\.url)
        guard !urls.isEmpty else { return }
        let remover = SafeRemover(allowedRoots: allowedRoots, mode: mode)
        let outcomes = await Task.detached { remover.remove(urls) }.value
        lastCleanSummary = AppModel.summary(outcomes, mode: mode)
        selection = []
        if mode != .dryRun, let rootURL = root?.url { scan(rootURL) }
    }
}
