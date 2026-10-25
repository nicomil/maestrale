import Foundation
import MacCleanerCore
import MacCleanerModules
import Observation

/// State shared by the whole window: scan results, selection and cleaning.
@MainActor
@Observable
final class AppModel {
    struct ModuleState: Identifiable {
        let module: any CleanerModule
        var report: ScanReport?
        var isScanning = false
        var error: String?
        var id: String { module.id }
    }

    var modules: [ModuleState] = []
    var selection: Set<URL> = []
    var removalMode: RemovalMode = .trash
    var isCleaning = false
    var lastCleanSummary: String?

    init() {
        var list: [ModuleState] = []
        if let junk = try? SystemJunkModule() { list.append(ModuleState(module: junk)) }
        list.append(ModuleState(module: TrashModule()))
        modules = list
    }

    func scan(_ id: String) async {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        modules[index].isScanning = true
        modules[index].error = nil
        let module = modules[index].module
        do {
            let report = try await Task.detached(priority: .userInitiated) { try await module.scan() }.value
            modules[index].report = report
            // Preselect only what the rules mark as safe and what we can remove ourselves.
            selection.subtract(report.allItems.map(\.url))
            selection.formUnion(report.allItems.filter { $0.autoSelect && !$0.needsHelper }.map(\.url))
        } catch {
            modules[index].error = error.localizedDescription
        }
        modules[index].isScanning = false
    }

    func selectedItems(in id: String) -> [ScanItem] {
        guard let report = modules.first(where: { $0.id == id })?.report else { return [] }
        return report.allItems.filter { selection.contains($0.url) && !$0.needsHelper }
    }

    func selectedSize(in id: String) -> Int64 {
        selectedItems(in: id).reduce(0) { $0 + $1.size }
    }

    func clean(_ id: String) async {
        let items = selectedItems(in: id)
        guard !items.isEmpty else { return }
        isCleaning = true
        let remover = SafeRemover(allowedRoots: AllowedRoots.user(), mode: removalMode)
        let outcomes = await Task.detached { remover.remove(items.map(\.url)) }.value

        let freed = outcomes.reduce(Int64(0)) { $0 + ((try? $1.result.get()) ?? 0) }
        let refused = outcomes.filter { (try? $0.result.get()) == nil }.count
        let verb = removalMode == .dryRun ? "Si libererebbero" : "Liberati"
        lastCleanSummary = "\(verb) \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))"
            + (refused > 0 ? " · \(refused) elementi non rimossi (vedi log)" : "")
        isCleaning = false
        if removalMode != .dryRun { await scan(id) }
    }
}
