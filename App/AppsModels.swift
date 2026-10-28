import AppKit
import Foundation
import MaestraleCore
import MaestraleModules
import Observation

/// State of the Uninstaller screen.
@MainActor
@Observable
final class UninstallerModel {
    enum Sort: String, CaseIterable, Identifiable {
        case name = "Nome", size = "Dimensione", lastUsed = "Ultimo uso"
        var id: String { rawValue }
    }

    var apps: [InstalledApp] = []
    var isLoading = false
    var search = ""
    var sort: Sort = .size
    var selectedApp: InstalledApp?
    /// Files of the selected app: the bundle first, then the leftovers.
    var files: [ScanItem] = []
    var fileSelection: Set<URL> = []
    var isWorking = false
    var message: String?
    /// Finds an app's leftovers; replaced in tests.
    var findLeftovers: @Sendable (InstalledApp, Set<String>) -> [ScanItem] = { app, otherIDs in
        LeftoverFinder().leftovers(for: .init(app: app), otherAppIDs: otherIDs)
    }

    var visibleApps: [InstalledApp] {
        let filtered = search.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search)
        }
        switch sort {
        case .name: return filtered
        case .size: return filtered.sorted { $0.size > $1.size }
        case .lastUsed: return filtered.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    func load() async {
        isLoading = true
        apps = await Task.detached(priority: .userInitiated) {
            await AppInventory().load().filter { !$0.isApple || $0.isWritable }
        }.value
        isLoading = false
    }

    /// Bumped on every selection change, so results of an older search are dropped.
    private var selectionGeneration = 0

    func select(_ app: InstalledApp?) async {
        // While removing, the files on screen are the ones being removed: the selection stays.
        guard !isWorking else { return }
        selectionGeneration += 1
        let generation = selectionGeneration
        selectedApp = app
        files = []
        fileSelection = []
        message = nil
        guard let app else { return }
        let otherIDs = Set(apps.filter { $0.url != app.url }.flatMap { [$0.bundleID] + $0.embeddedBundleIDs })
        let find = findLeftovers
        let leftovers = await Task.detached { find(app, otherIDs) }.value
        // Another app was chosen in the meantime: these files belong to the old one.
        guard generation == selectionGeneration, selectedApp?.url == app.url else { return }
        let bundle = ScanItem(url: app.url, size: app.size, risk: .medium, autoSelect: true,
                              needsHelper: !app.isWritable, detail: "Applicazione")
        files = [bundle] + leftovers.sorted { $0.size > $1.size }
        // The bundle is what an uninstall is about: it stays selected even when
        // removing it takes the password. Other items needing it wait for the user.
        fileSelection = Set(files.filter { $0.autoSelect && (!$0.needsHelper || $0.url == app.url) }.map(\.url))
    }

    var selectedFiles: [ScanItem] { files.filter { fileSelection.contains($0.url) } }

    func selectAllFiles() { fileSelection = Set(files.map(\.url)) }

    func deselectAllFiles() { fileSelection = [] }

    /// Removes system items with the password; replaced in tests.
    var removeAsAdmin: @MainActor ([ScanItem], RemovalMode) async -> (outcomes: [RemovalOutcome], note: String) = {
        await AppModel.removeAsAdmin($0, mode: $1)
    }

    /// Items the user could not remove for lack of permission, but that live
    /// where the helper may act: a bundle owned by root, for instance, when
    /// the ownership check did not foresee it.
    nonisolated static func retryableAsAdmin(_ outcomes: [RemovalOutcome], items: [ScanItem]) -> [ScanItem] {
        let roots = AdminRunner.systemRoots.map(\.path)
        return outcomes.compactMap { outcome in
            guard case .failure(.failed) = outcome.result,
                  roots.contains(where: { outcome.url.path.hasPrefix($0 + "/") }) else { return nil }
            return items.first { $0.url == outcome.url }
        }
    }

    /// Removes the selected files. With `reset`, the app itself is kept and
    /// only its data is removed, so it starts as freshly installed.
    func run(reset: Bool, mode: RemovalMode) async {
        guard let app = selectedApp, !isWorking else { return }
        // Everything is decided before the first wait: what the user confirmed
        // is what gets removed, whatever happens on screen meanwhile.
        let generation = selectionGeneration
        let chosen = selectedFiles.filter { !reset || $0.url != app.url }
        guard !chosen.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        let center = ProgressCenter.shared
        center.begin(reset ? "Reset di \(app.name)" : "Disinstallazione di \(app.name)", total: chosen.count,
                     bytesTotal: chosen.reduce(Int64(0)) { $0 + $1.size }, canStop: true,
                     detail: mode == .dryRun ? nil : "Chiudo \(app.name)…")
        defer { center.end() }
        if mode != .dryRun, !(await quit(app)) {
            message = "Chiudi \(app.name) e riprova."
            return
        }
        guard generation == selectionGeneration else { return }
        let urls = chosen.filter { !$0.needsHelper }.map(\.url)
        let remover = SafeRemover(allowedRoots: AllowedRoots.appSupport(), mode: mode)
        let sizes = Dictionary(chosen.map { ($0.url, $0.size) }, uniquingKeysWith: { first, _ in first })
        let report = center.removalReporter(verb: AppModel.verb(for: mode), sizes: sizes)
        let goOn = center.continuation()
        var outcomes = await Task.detached { remover.remove(urls, progress: report, shouldContinue: goOn) }.value
        var note = ""
        let interrupted = outcomes.count < urls.count
        if interrupted { note = " · interrotto: \(chosen.count - outcomes.count) elementi non toccati" }
        // What failed for permissions under a system folder gets one more try with the password.
        let retry = mode == .dryRun || interrupted ? [] : Self.retryableAsAdmin(outcomes, items: chosen)
        let adminItems = interrupted ? [] : chosen.filter(\.needsHelper) + retry
        if !adminItems.isEmpty {
            center.phase("Elementi di sistema: macOS chiede la password…")
            let result = await removeAsAdmin(adminItems, mode)
            let retried = Set(result.outcomes.map(\.url))
            outcomes.removeAll { retried.contains($0.url) }
            outcomes += result.outcomes
            note = result.note
        }
        message = AppModel.summary(outcomes, mode: mode) + note
        isWorking = false
        if mode != .dryRun {
            if !reset && outcomes.contains(where: { $0.url == app.url && (try? $0.result.get()) != nil }) {
                apps.removeAll { $0.url == app.url }
                selectionGeneration += 1
                selectedApp = nil
                files = []
                fileSelection = []
            } else {
                let note = message
                center.phase("Rileggo i file dell'app…")
                await select(app)
                message = note
            }
        }
    }

    /// Asks the app to quit and waits a few seconds. Returns false if it is still open.
    private func quit(_ app: InstalledApp) async -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        guard !running.isEmpty else { return true }
        running.forEach { $0.terminate() }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(250))
            if running.allSatisfy(\.isTerminated) { return true }
        }
        return false
    }
}

/// State of the Updates screen.
@MainActor
@Observable
final class UpdatesModel {
    var updates: [AppUpdate] = []
    var isChecking = false
    var checkedApps = 0
    var lastCheck: Date?
    var busy: Set<URL> = []
    var messages: [URL: String] = [:]

    func check() async {
        isChecking = true
        let result = await Task.detached(priority: .userInitiated) { () -> ([InstalledApp], [AppUpdate]) in
            let apps = await AppInventory().load(computeSizes: false)
            return (apps, await UpdateChecker().check(apps))
        }.value
        checkedApps = result.0.count
        updates = result.1
        lastCheck = Date()
        isChecking = false
    }

    /// Drops the updates the user installed meanwhile: each app is read again
    /// from disk and kept only while its version is still the old one.
    func refresh() async {
        guard !updates.isEmpty, !isChecking else { return }
        let pending = updates
        let still = await Task.detached(priority: .utility) {
            pending.filter { update in
                guard let installed = AppInventory.read(update.app.url, computeSize: false) else { return false }
                return update.isStillPending(for: installed)
            }
        }.value
        let stillIDs = Set(still.map(\.id))
        for update in updates where !stillIDs.contains(update.id) { messages[update.id] = nil }
        updates = still
    }

    /// Sparkle apps update themselves: open them. App Store: open the page.
    /// Homebrew: run `brew upgrade --cask`.
    func update(_ update: AppUpdate) async {
        switch update.source {
        case .sparkle:
            NSWorkspace.shared.openApplication(at: update.app.url, configuration: .init(), completionHandler: nil)
            messages[update.id] = "Aperta: usa \"Controlla aggiornamenti\" nel suo menu."
        case .appStore:
            if let page = update.infoURL { NSWorkspace.shared.open(page) }
        case .homebrew:
            guard let token = update.caskToken else { return }
            busy.insert(update.id)
            let ok = await Task.detached { Self.brewUpgrade(token) }.value
            busy.remove(update.id)
            messages[update.id] = ok ? "Aggiornata" : "brew upgrade non riuscito (vedi Terminale)"
            if ok { updates.removeAll { $0.id == update.id } }
        }
        await refresh()
    }

    nonisolated static func brewUpgrade(_ token: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        process.arguments = ["upgrade", "--cask", token]
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
