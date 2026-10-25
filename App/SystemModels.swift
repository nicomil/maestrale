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

    func clean(dryRun: Bool) async {
        let chosen = items.filter { selection.contains($0.id) }
        var cleaned = 0
        var problems: [String] = []
        for item in chosen {
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
        if !dryRun { await scan() }
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
    var results: [String: String] = [:]
    var hasScanned = false
    var message: String?

    func scan() async {
        launchItems = await Task.detached { LaunchItemsScanner().scan() }.value
        hasScanned = true
    }

    func toggle(_ item: LaunchItem) async {
        if item.domain == .userAgent {
            let enable = item.isDisabled
            _ = await Task.detached { LaunchItemsScanner().setUserAgent(item, enabled: enable) }.value
        } else if !item.isDisabled {
            do {
                try await Task.detached { try AdminRunner().run(.bootoutDaemon(label: item.label)) }.value
            } catch {
                message = "\(item.label): non fermato"
            }
        }
        await scan()
    }

    /// Moves a user agent's plist to the Trash, or deletes a system one with the password.
    func remove(_ item: LaunchItem) async {
        if item.domain == .userAgent {
            _ = await Task.detached { LaunchItemsScanner().setUserAgent(item, enabled: false) }.value
            let remover = SafeRemover(allowedRoots: AllowedRoots.appSupport(), mode: .trash)
            let outcome = await Task.detached { remover.remove([item.plist]) }.value
            message = AppModel.summary(outcome, mode: .trash)
        } else {
            do {
                try await Task.detached {
                    let runner = AdminRunner()
                    try? runner.run(.bootoutDaemon(label: item.label))
                    try runner.run(.remove([item.plist]))
                }.value
                message = "\(item.label) rimosso"
            } catch {
                message = "\(item.label): non rimosso"
            }
        }
        await scan()
    }

    func run(_ task: MaintenanceTask) async {
        running.insert(task.id)
        do {
            try await task.run()
            results[task.id] = "Fatto alle \(Date().formatted(date: .omitted, time: .shortened))"
        } catch AdminError.cancelled {
            results[task.id] = nil
        } catch PrivacyError.browserRunning(let name) {
            results[task.id] = "Chiudi \(name) e riprova"
        } catch {
            results[task.id] = "Non riuscito"
        }
        running.remove(task.id)
    }
}
