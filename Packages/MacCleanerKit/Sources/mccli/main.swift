import Foundation
import MacCleanerCore
import MacCleanerModules

// Read-only: prints what each module finds. Usage: mccli <module>
// Modules: junk, trash, large, duplicates, similar, orphans, apps, updates

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
default:
    print("Uso: mccli junk|trash|large|duplicates|similar|orphans|apps|updates")
}
print(String(format: "(%.1fs)", Date().timeIntervalSince(started)))
