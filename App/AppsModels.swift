import AppKit
import Foundation
import MacCleanerCore
import MacCleanerModules
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

    func select(_ app: InstalledApp?) async {
        selectedApp = app
        files = []
        fileSelection = []
        message = nil
        guard let app else { return }
        let leftovers = await Task.detached { LeftoverFinder().leftovers(for: .init(app: app)) }.value
        let bundle = ScanItem(url: app.url, size: app.size, risk: .medium, autoSelect: true,
                              needsHelper: !app.isWritable, detail: "Applicazione")
        files = [bundle] + leftovers.sorted { $0.size > $1.size }
        fileSelection = Set(files.filter { $0.autoSelect && !$0.needsHelper }.map(\.url))
    }

    var selectedFiles: [ScanItem] { files.filter { fileSelection.contains($0.url) && !$0.needsHelper } }

    /// Removes the selected files. With `reset`, the app itself is kept and
    /// only its data is removed, so it starts as freshly installed.
    func run(reset: Bool, mode: RemovalMode) async {
        guard let app = selectedApp else { return }
        isWorking = true
        defer { isWorking = false }
        if mode != .dryRun, !(await quit(app)) {
            message = "Chiudi \(app.name) e riprova."
            return
        }
        let urls = selectedFiles.map(\.url).filter { !reset || $0 != app.url }
        let remover = SafeRemover(allowedRoots: AllowedRoots.appSupport(), mode: mode)
        let outcomes = await Task.detached { remover.remove(urls) }.value
        message = AppModel.summary(outcomes, mode: mode)
        if mode != .dryRun {
            if !reset && outcomes.contains(where: { $0.url == app.url && (try? $0.result.get()) != nil }) {
                apps.removeAll { $0.url == app.url }
                selectedApp = nil
                files = []
            } else {
                await select(app)
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
