import Foundation
import MaestraleCore
import MaestraleModules

// Read-only: prints what each module finds. Usage: mscli <module>
// Modules: junk, trash, large, duplicates, similar, orphans, apps, updates, privacy, launch

func show(_ report: ScanReport, limit: Int = 8) {
    print("Totale: \(ByteCountFormatter.string(fromByteCount: report.totalSize, countStyle: .file))")
    for category in report.categories.prefix(limit) {
        print("• \(category.title) — \(category.items.count) elementi, "
              + ByteCountFormatter.string(fromByteCount: category.totalSize, countStyle: .file))
        for item in category.items.prefix(3) {
            print("    \(item.autoSelect ? "[x]" : "[ ]") \(item.url.path) "
                  + ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
        }
    }
    if report.categories.count > limit { print("… altre \(report.categories.count - limit) categorie") }
}

let command = CommandLine.arguments.dropFirst().first ?? "help"
let started = Date()
switch command {
case "junk": show(try await SystemJunkModule().scan())
case "trash": show(try await TrashModule().scan())
case "large": show(try await LargeOldFilesModule().scan())
case "duplicates": show(try await DuplicatesModule().scan())
case "similar": show(try await SimilarImagesModule().scan())
case "orphans": show(try await OrphanLeftoversModule().scan(), limit: 15)
case "apps":
    let apps = await AppInventory().load()
    print("\(apps.count) app")
    for app in apps.sorted(by: { $0.size > $1.size }).prefix(10) {
        let leftovers = LeftoverFinder().leftovers(for: .init(app: app))
        print("\(app.name) \(app.version) — \(ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file)), "
              + "\(leftovers.count) file collegati, team \(app.teamID ?? "-")")
    }
case "updates":
    let apps = await AppInventory().load(computeSizes: false)
    let updates = await UpdateChecker().check(apps)
    print("\(updates.count) aggiornamenti su \(apps.count) app")
    for u in updates { print("\(u.app.name): \(u.app.version) → \(u.availableVersion) [\(u.source.rawValue)]") }
case "privacy":
    for item in PrivacyScanner().scan() {
        print("\(item.autoSelect ? "[x]" : "[ ]") \(item.owner) \(item.profile ?? "") — \(item.kind.title): \(item.count)")
    }
    print("Wi-Fi salvate: \(WiFiNetworks.preferred().count)")
    print("Non leggibili senza Accesso completo al disco: " + PrivacyScanner().unreadableOwners().joined(separator: ", "))
case "launch":
    let items = LaunchItemsScanner().scan()
    print("\(items.count) elementi di avvio, \(items.filter(\.isBroken).count) rotti")
    for item in items.prefix(25) {
        print("\(item.isDisabled ? "off" : "on ") \(item.isBroken ? "ROTTO " : "")\(item.domain.rawValue): \(item.label)")
    }
    print("Manutenzione disponibile: " + MaintenanceTask.available().map(\.title).joined(separator: ", "))
case "mail": show(try await MailAttachmentsModule().scan())
case "installers": show(try await InstallersModule().scan())
case "malware":
    let scanner = MalwareScanner()
    let status = scanner.protectionStatus()
    print("Gatekeeper \(status.gatekeeperEnabled.map { $0 ? "on" : "OFF" } ?? "?"), SIP \(status.sipEnabled.map { $0 ? "on" : "OFF" } ?? "?"), "
          + "firewall \(status.firewallEnabled.map { $0 ? "on" : "off" } ?? "?"), XProtect \(status.xprotectVersion ?? "?")")
    for finding in scanner.scan() {
        print("[\(finding.severity)] \(finding.category.title) · \(finding.title): \(finding.reasons.joined(separator: "; "))")
        for line in finding.evidence { print("    \(line)") }
    }
case "processes":
    let sampler = ProcessSampler()
    _ = sampler.sample()
    try await Task.sleep(for: .seconds(2))
    let activities = sampler.sample().sorted { $0.cpu > $1.cpu }
    for activity in activities.prefix(15) {
        print(String(format: "%6d %5.0f%% %8@ net %8@/s disk %8@/s  %@", activity.process.pid, activity.cpu * 100,
                     ByteCountFormatter.string(fromByteCount: Int64(activity.memory), countStyle: .memory),
                     ByteCountFormatter.string(fromByteCount: Int64(activity.networkInPerSecond + activity.networkOutPerSecond), countStyle: .file),
                     ByteCountFormatter.string(fromByteCount: Int64(activity.diskReadPerSecond + activity.diskWritePerSecond), countStyle: .file),
                     activity.process.path ?? activity.process.name))
    }
    for finding in ProcessesCheck().run(CheckContext(launchItems: [])) {
        print("[\(finding.severity)] \(finding.title): \(finding.reasons.joined(separator: "; "))")
        for line in finding.evidence { print("    \(line)") }
    }
case "signatures":
    let store = RuleStore()
    print("Regole: \(store.ruleSources().map(\.namespace).joined(separator: ", ")) · hash noti: \(KnownHashes.load(store.hashFiles()).entries.count)")
    let enumerationStart = Date()
    let candidates = ScanTargets.candidates(home: FileManager.default.homeDirectoryForCurrentUser, launchItems: LaunchItemsScanner().scan())
    print("\(candidates.count) file candidati in \(String(format: "%.1f", Date().timeIntervalSince(enumerationStart)))s")
    if CommandLine.arguments.contains("--list") { for url in candidates { print("  \(url.path)") } }
    if CommandLine.arguments.contains("--time"), let engine = try? YaraEngine(sources: store.ruleSources()) {
        var slow: [(Double, String, Int)] = []
        let scanStart = Date()
        for url in candidates {
            let t = Date()
            _ = try? engine.scan(file: url)
            let d = Date().timeIntervalSince(t)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if d > 0.3 { slow.append((d, url.path, size)) }
        }
        print("scansione YARA \(String(format: "%.1f", Date().timeIntervalSince(scanStart)))s")
        for (d, p, sz) in slow.sorted(by: { $0.0 > $1.0 }).prefix(10) { print(String(format: "%6.1fs %10d %@", d, sz, p)) }
        exit(0)
    }
    for finding in SignatureScanCheck().run(CheckContext()) {
        print("[\(finding.severity)] \(finding.title): \(finding.reasons.joined(separator: "; "))")
        for line in finding.evidence { print("    \(line)") }
    }
case "posture":
    let context = CheckContext(launchItems: [])
    for finding in (PostureCheck().run(context) + XProtectCheck().run(context)) {
        print("[\(finding.severity)] \(finding.title): \(finding.reasons.joined(separator: "; "))")
        for line in finding.evidence { print("    \(line)") }
    }
default:
    print("Uso: mscli junk|trash|large|duplicates|similar|orphans|apps|updates|privacy|launch|mail|installers|malware|posture|processes|signatures")
}
print(String(format: "(%.1fs)", Date().timeIntervalSince(started)))
