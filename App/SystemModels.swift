import Foundation
import MacCleanerCore
import MacCleanerModules
import Observation

@MainActor
@Observable
final class PrivacyModel {
    var items: [PrivacyItem] = []
    var selection: Set<String> = []
    var wifiNetworks: [String] = []
    var unreadable: [String] = []
    var isScanning = false
    var hasScanned = false
    var message: String?

    /// Items grouped by owner (browser or macOS), in a stable order.
    var groups: [(owner: String, items: [PrivacyItem])] {
        var order: [String] = []
        var map: [String: [PrivacyItem]] = [:]
        for item in items {
            if map[item.owner] == nil { order.append(item.owner) }
            map[item.owner, default: []].append(item)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    func scan() async {
        isScanning = true
        let found = await Task.detached {
            (PrivacyScanner().scan(), WiFiNetworks.preferred(), PrivacyScanner().unreadableOwners())
        }.value
        items = found.0
        wifiNetworks = found.1
        unreadable = found.2
        selection = Set(items.filter(\.autoSelect).map(\.id))
        isScanning = false
        hasScanned = true
    }

    func selectAll() { selection = Set(items.map(\.id)) }

    func deselectAll() { selection = [] }

    func clean(dryRun: Bool) async {
        let chosen = items.filter { selection.contains($0.id) }
        var cleaned = 0
        var problems: [String] = []
        let center = ProgressCenter.shared
        center.begin(dryRun ? "Controllo della privacy" : "Pulizia della privacy", total: chosen.count)
        defer { center.end() }
        for (index, item) in chosen.enumerated() {
            center.update(completed: index, detail: "\(item.owner): \(item.kind.title)")
            do {
                try await PrivacyScanner().clean(item, dryRun: dryRun)
                cleaned += 1
            } catch PrivacyError.browserRunning(let name) {
                if !problems.contains("Chiudi \(name)") { problems.append("Chiudi \(name)") }
            } catch {
                problems.append("\(item.owner): \(item.kind.title)")
            }
        }
        message = (dryRun ? "Si pulirebbero \(cleaned) voci" : "Pulite \(cleaned) voci")
            + (problems.isEmpty ? "" : " · " + problems.joined(separator: ", "))
        if !dryRun {
            center.update(completed: chosen.count, detail: "Nuova scansione…")
            await scan()
        }
    }

    func forget(_ network: String) async {
        do {
            try await Task.detached { try AdminRunner().run(.removeWiFiNetwork(network)) }.value
            wifiNetworks.removeAll { $0 == network }
            message = "Rete \(network) dimenticata"
        } catch AdminError.cancelled {
            message = nil
        } catch {
            message = "Impossibile dimenticare \(network)"
        }
    }
}

@MainActor
@Observable
final class PerformanceModel {
    var launchItems: [LaunchItem] = []
    var tasks: [MaintenanceTask] = MaintenanceTask.available()
    var running: Set<String> = []
    var results: [String: MaintenanceResult] = [:]

    /// What a maintenance card shows after running.
    enum MaintenanceResult: Equatable {
        case done(String, Date)
        case skipped(String)
        case failed(String)
    }
    var hasScanned = false
    var message: String?

    func scan() async {
        launchItems = await Task.detached { LaunchItemsScanner().scan() }.value
        hasScanned = true
    }

    func toggle(_ item: LaunchItem) async {
        do {
            if item.domain != .systemDaemon {
                let enable = item.isDisabled
                try await Task.detached { try LaunchItemsScanner().setAgent(item, enabled: enable) }.value
            } else if !item.isDisabled {
                try await Task.detached { try LaunchItemsScanner().stopDaemon(item) }.value
            }
        } catch AdminError.cancelled {
        } catch {
            message = "\(item.label): non fermato (\(error))"
        }
        await scan()
    }

    /// Stops a launch item, then moves its plist to the Trash (a system one with
    /// the password). If it does not stop, nothing is moved.
    func remove(_ item: LaunchItem) async {
        do {
            try await Task.detached { try LaunchItemsScanner().remove(item) }.value
            message = "\(item.label) rimosso"
        } catch AdminError.cancelled {
        } catch {
            message = "\(item.label): non rimosso (\(error))"
        }
        await scan()
    }

    func run(_ task: MaintenanceTask) async {
        running.insert(task.id)
        let center = ProgressCenter.shared
        center.begin(task.title, detail: task.adminOperation != nil ? "In corso… macOS chiede la password" : "In corso…")
        defer { center.end() }
        do {
            let summary = try await task.run()
            results[task.id] = .done(summary, Date())
        } catch AdminError.cancelled {
            results[task.id] = nil
        } catch MaintenanceError.nothingToDo(let why) {
            results[task.id] = .skipped(why)
        } catch AdminError.failed(let message) {
            results[task.id] = .failed(message.isEmpty ? "il comando è uscito con un errore" : message)
        } catch AdminError.refused(let why) {
            results[task.id] = .failed(why)
        } catch PrivacyError.browserRunning(let name) {
            results[task.id] = .failed("Chiudi \(name) e riprova")
        } catch PrivacyError.failed(let why) {
            results[task.id] = .failed(why)
        } catch {
            results[task.id] = .failed(error.localizedDescription)
        }
        running.remove(task.id)
    }
}
