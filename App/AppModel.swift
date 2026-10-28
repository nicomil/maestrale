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
    case activity
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
        var scanStarted: Date?
        var error: String?
        var lastClean: CleanOutcome?
        var lastCleanSummary: String? { lastClean?.summary }
        var id: String { module.id }
    }

    struct CleanOutcome {
        let summary: String
        let mode: RemovalMode
    }

    private var scanTasks: [String: Task<Void, Never>] = [:]

    func startScan(_ id: String) {
        scanTasks[id]?.cancel()
        scanTasks[id] = Task { await scan(id) }
    }

    func cancelScan(_ id: String) {
        scanTasks[id]?.cancel()
        scanTasks[id] = nil
        modules[id]?.isScanning = false
    }

    /// Short text for the sidebar: what the last scan found.
    func badge(for destination: Destination) -> String? {
        switch destination {
        case .module(let id):
            guard let state = modules[id] else { return nil }
            if state.isScanning { return "…" }
            guard let size = state.report?.totalSize, size > 0 else { return nil }
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        case .updates:
            return updates.updates.isEmpty ? nil : "\(updates.updates.count)"
        case .protection:
            let count = protection.visibleFindings.filter { $0.severity >= .warning }.count
            return count == 0 ? nil : "\(count)"
        default:
            return nil
        }
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
    let activity = ActivityModel()
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
                SidebarEntry(destination: .activity, title: "Attività", icon: "waveform.path.ecg"),
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

    /// True inside the unit tests, which run in the app: scheduled cleanings
    /// must not start there.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func startScheduler() {
        scheduler.start(self)
    }

    func scan(_ id: String) async {
        guard let module = modules[id]?.module else { return }
        modules[id]?.isScanning = true
        modules[id]?.scanStarted = Date()
        modules[id]?.error = nil
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Scansione")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        do {
            let work = Task.detached(priority: .userInitiated) { try await module.scan() }
            let report = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            modules[id]?.report = report
            modules[id]?.lastClean = nil
            // Preselect only what the module marks as safe and what we can remove ourselves.
            selection.subtract(report.allItems.map(\.url))
            selection.formUnion(report.allItems.filter { $0.autoSelect && !$0.needsHelper }.map(\.url))
            // Items needing the password stay unselected until the user picks them.
        } catch is CancellationError {
            // The user pressed Annulla: keep the previous results.
        } catch {
            modules[id]?.error = error.localizedDescription
        }
        modules[id]?.isScanning = false
    }

    func selectedItems(in id: String) -> [ScanItem] {
        guard let report = modules[id]?.report else { return [] }
        return report.allItems.filter { selection.contains($0.url) }
    }

    /// The mode a clean really runs with. "Move to the Trash" means nothing
    /// for what is already in the Trash: emptying it deletes for good.
    nonisolated static func effectiveMode(moduleID: String, chosen: RemovalMode) -> RemovalMode {
        moduleID == TrashModule.id && chosen == .trash ? .delete : chosen
    }

    func effectiveMode(in id: String) -> RemovalMode {
        Self.effectiveMode(moduleID: id, chosen: removalMode)
    }

    /// Items of a report that the filter of the results list shows.
    nonisolated static func visibleItems(_ report: ScanReport, matching filter: String) -> [ScanItem] {
        filter.isEmpty ? report.allItems
            : report.allItems.filter { $0.url.path.localizedCaseInsensitiveContains(filter) }
    }

    /// Selects every visible item, except the copy that must stay in each group.
    func selectAll(in id: String, matching filter: String = "") {
        guard let report = modules[id]?.report else { return }
        let kept = Set(report.categories.compactMap(\.keep))
        selection.formUnion(Self.visibleItems(report, matching: filter).map(\.url).filter { !kept.contains($0) })
    }

    func deselectAll(in id: String, matching filter: String = "") {
        guard let report = modules[id]?.report else { return }
        selection.subtract(Self.visibleItems(report, matching: filter).map(\.url))
    }

    func selectedSize(in id: String) -> Int64 {
        selectedItems(in: id).reduce(Int64(0)) { $0 + $1.size }
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
        guard let module = modules[id]?.module, let report = modules[id]?.report,
              fullySelectedCopyGroups(in: id).isEmpty else { return }
        var items = selectedItems(in: id)
        guard !items.isEmpty else { return }
        // Mail rewrites its folders while it is open.
        if id == "mail-attachments", PrivacyScanner.isRunning("com.apple.mail") {
            modules[id]?.error = "Chiudi Mail e riprova."
            return
        }
        modules[id]?.error = nil
        isCleaning = true
        let mode = effectiveMode(in: id)
        // Files may have changed since the scan: a group of copies is skipped
        // unless a copy that stays is still there (and, for duplicates, identical).
        let selectedURLs = Set(items.map(\.url))
        let changed = await Task.detached {
            Self.changedCopyGroups(report, selected: selectedURLs, identical: id == "duplicates")
        }.value
        items.removeAll { changed.urls.contains($0.url) }
        // An app opened after the scan: its caches stay until it is closed.
        var skippedRunning = 0
        if id == SystemJunkModule.id {
            let running = SystemJunkModule.runningBundleIdentifiers()
            let before = items.count
            items.removeAll { RuleEngine.isProtected($0.url, by: running) }
            skippedRunning = before - items.count
        }
        // Only the Trash unlocks items: a locked file is what keeps it from emptying.
        let remover = SafeRemover(allowedRoots: module.allowedRoots, mode: mode, unlocksItems: id == TrashModule.id)
        let userItems = items.filter { !$0.needsHelper }
        let adminItems = items.filter(\.needsHelper)
        let center = ProgressCenter.shared
        center.begin(id == TrashModule.id ? "Svuotamento del Cestino" : "Pulizia: \(module.title)",
                     total: items.count, bytesTotal: items.reduce(Int64(0)) { $0 + $1.size }, canStop: true)
        defer { center.end() }
        let reportProgress = center.removalReporter(verb: Self.verb(for: mode), sizes: Self.sizes(of: items))
        let goOn = center.continuation()
        let userURLs = userItems.map(\.url)
        var outcomes = await Task.detached { remover.remove(userURLs, progress: reportProgress, shouldContinue: goOn) }.value
        let interrupted = outcomes.count < userItems.count
        var adminNote = ""
        if interrupted {
            adminNote = " · interrotto: \(items.count - outcomes.count) elementi non toccati"
        } else if !adminItems.isEmpty {
            center.phase("Elementi di sistema: macOS chiede la password…")
            let result = await Self.removeAsAdmin(adminItems, mode: mode)
            outcomes += result.outcomes
            adminNote = result.note
        }
        if changed.groups > 0 {
            adminNote += " · \(changed.groups) gruppi saltati perché cambiati dopo la scansione"
        }
        if skippedRunning > 0 {
            adminNote += " · \(skippedRunning) elementi saltati perché la loro app è aperta"
        }
        let outcome = CleanOutcome(summary: Self.summary(outcomes, mode: mode) + adminNote, mode: mode)
        isCleaning = false
        if mode != .dryRun {
            center.update(completed: items.count, detail: "Nuova scansione…")
            await scan(id)
        }
        modules[id]?.lastClean = outcome
    }

    /// What the progress banner says is happening to each item.
    static func verb(for mode: RemovalMode) -> String {
        switch mode {
        case .delete: "Elimino"
        case .trash: "Sposto nel Cestino"
        case .dryRun: "Controllo"
        }
    }

    static func sizes(of items: [ScanItem]) -> [URL: Int64] {
        Dictionary(items.map { ($0.url, $0.size) }, uniquingKeysWith: { first, _ in first })
    }

    /// Selected items of copy groups that are no longer safe to clean.
    nonisolated static func changedCopyGroups(_ report: ScanReport, selected: Set<URL>,
                                              identical: Bool) -> (urls: Set<URL>, groups: Int) {
        var urls: Set<URL> = []
        var groups = 0
        for category in report.categories where category.keep != nil {
            let chosen = category.items.map(\.url).filter(selected.contains)
            guard !chosen.isEmpty else { continue }
            let staying = category.items.map(\.url).filter { !selected.contains($0) }
            let safe = staying.contains { stay in
                FileManager.default.fileExists(atPath: stay.path)
                    && (!identical || DuplicatesModule.stillDuplicates(chosen, of: stay))
            }
            if !safe {
                urls.formUnion(chosen)
                groups += 1
            }
        }
        return (urls, groups)
    }

    /// Removes system items with one administrator password prompt, following
    /// the chosen mode: to the Trash (restorable), deleted, or only checked.
    static func removeAsAdmin(_ items: [ScanItem], mode: RemovalMode) async -> (outcomes: [RemovalOutcome], note: String) {
        let urls = items.map(\.url)
        let runner = AdminRunner()
        let operation: AdminOperation = mode == .delete ? .remove(urls) : .moveToTrash(urls)
        do {
            if mode == .dryRun {
                _ = try runner.command(for: operation)
            } else {
                try await Task.detached { try runner.run(operation) }.value
            }
            return (items.map { RemovalOutcome(url: $0.url, result: .success($0.size)) }, "")
        } catch AdminError.itemsFailed(let done, let failed) {
            // Some items were handled, some not: report each one as it went.
            let handled = Set(done)
            let outcomes = items.map { item in
                AdminRunner.helperPath(of: item.url).map(handled.contains) == true
                    ? RemovalOutcome(url: item.url, result: .success(item.size))
                    : RemovalOutcome(url: item.url, result: .failure(.failed(failed.first ?? "non rimosso")))
            }
            return (outcomes, "")
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

    /// Bumped on every scan and cancel: an older scan that is still winding
    /// down must not touch the screen.
    private var scanGeneration = 0

    func scan(_ url: URL) {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        root = nil
        path = []
        selection = []
        scannedFiles = 0
        scannedBytes = 0
        let counter = ScanCounter()
        scanTask = Task {
            // Keeps App Nap from throttling the scan and the progress label
            // while the window is in the background.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Space Lens")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let progress = Task {
                while !Task.isCancelled, generation == scanGeneration {
                    let snap = counter.snapshot
                    scannedFiles = snap.files
                    scannedBytes = snap.bytes
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            // A detached task does not inherit cancellation: pass it on, so
            // Cancel really stops the walk instead of letting it run on.
            let work = Task.detached(priority: .userInitiated) {
                await SpaceLensScanner().scan(url, counter: counter)
            }
            let node = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            progress.cancel()
            guard generation == scanGeneration, !Task.isCancelled else { return }
            root = node
            isScanning = false
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanGeneration += 1
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

    /// Everything in the open folder except the "small files" aggregate, which cannot be removed.
    var selectableNodes: [DiskNode] { current?.children.filter { !$0.isAggregate } ?? [] }

    func selectAll() { selection = Set(selectableNodes.map(\.url)) }

    func deselectAll() { selection = [] }

    func trashSelected(mode: RemovalMode) async {
        let nodes = selectedNodes()
        let urls = nodes.map(\.url)
        guard !urls.isEmpty else { return }
        let center = ProgressCenter.shared
        center.begin("Rimozione da Space Lens", total: urls.count,
                     bytesTotal: nodes.reduce(Int64(0)) { $0 + $1.size }, canStop: true)
        defer { center.end() }
        let sizes = Dictionary(nodes.map { ($0.url, $0.size) }, uniquingKeysWith: { first, _ in first })
        let report = center.removalReporter(verb: AppModel.verb(for: mode), sizes: sizes)
        let goOn = center.continuation()
        let remover = SafeRemover(allowedRoots: allowedRoots, mode: mode)
        let outcomes = await Task.detached { remover.remove(urls, progress: report, shouldContinue: goOn) }.value
        let untouched = urls.count - outcomes.count
        lastCleanSummary = AppModel.summary(outcomes, mode: mode)
            + (untouched > 0 ? " · interrotto: \(untouched) elementi non toccati" : "")
        selection = []
        if mode != .dryRun, let rootURL = root?.url { scan(rootURL) }
    }
}
