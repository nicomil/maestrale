import Foundation
import MacCleanerCore
import Testing
@testable import MacCleanerModules

@Suite struct AppsTests {
    @Test func leftoverFinderMatchesBundleIDsNotLookalikes() throws {
        let home = try FakeHome(); defer { home.remove() }
        let lib = "Library/"
        try home.file(lib + "Application Support/com.acme.Editor/data.db", bytes: 4096)
        try home.file(lib + "Application Support/Editor/settings.json", bytes: 4096)
        try home.file(lib + "Caches/com.acme.Editor/cache.bin", bytes: 4096)
        try home.file(lib + "Caches/com.acme.EditorPro/cache.bin", bytes: 4096) // different app
        try home.file(lib + "Preferences/com.acme.Editor.plist", bytes: 4096)
        try home.file(lib + "Preferences/com.acme.Editor.helper.plist", bytes: 4096)
        try home.file(lib + "Containers/com.acme.Editor.ShareExtension/Data/x", bytes: 4096)
        try home.file(lib + "Group Containers/ABCDE12345.com.acme.Editor/x", bytes: 4096)
        try home.file(lib + "Group Containers/ABCDE12345.com/x", bytes: 4096) // too generic
        try home.file(lib + "Saved Application State/com.acme.Editor.savedState/w", bytes: 4096)
        try home.file(lib + "Caches/Helper/x", bytes: 4096)

        let identity = LeftoverFinder.Identity(
            bundleIDs: ["com.acme.Editor", "com.acme.Editor.ShareExtension"], name: "Editor", teamID: "ABCDE12345")
        let finder = LeftoverFinder(home: home.url, systemLibrary: home.url.appendingPathComponent("NoSystem"))
        let found = Set(finder.leftovers(for: identity).map { $0.url.path.replacingOccurrences(of: home.url.path + "/", with: "") })

        #expect(found == [
            lib + "Application Support/com.acme.Editor",
            lib + "Application Support/Editor",
            lib + "Caches/com.acme.Editor",
            lib + "Preferences/com.acme.Editor.plist",
            lib + "Preferences/com.acme.Editor.helper.plist",
            lib + "Containers/com.acme.Editor.ShareExtension",
            lib + "Group Containers/ABCDE12345.com.acme.Editor",
            lib + "Saved Application State/com.acme.Editor.savedState",
        ])
    }

    @Test func nameOnlyMatchesAreNotPreselected() throws {
        let home = try FakeHome(); defer { home.remove() }
        try home.file("Library/Application Support/Editor/settings.json", bytes: 4096)
        let finder = LeftoverFinder(home: home.url, systemLibrary: home.url.appendingPathComponent("NoSystem"))
        let item = try #require(finder.leftovers(for: .init(bundleIDs: ["com.acme.Editor"], name: "Editor", teamID: nil)).first)
        #expect(item.autoSelect == false)
        #expect(item.risk == .high) // Application Support holds the app's data
    }

    @Test func appDataIsNeverPreselected() throws {
        let home = try FakeHome(); defer { home.remove() }
        let lib = "Library/"
        try home.file(lib + "Application Support/com.acme.Notes/notes.db", bytes: 4096)
        try home.file(lib + "Containers/com.acme.Notes/Data/Documents/a.txt", bytes: 4096)
        try home.file(lib + "Group Containers/ABCDE12345.com.acme.Notes/x", bytes: 4096)
        try home.file(lib + "Caches/com.acme.Notes/cache.bin", bytes: 4096)
        let finder = LeftoverFinder(home: home.url, systemLibrary: home.url.appendingPathComponent("NoSystem"))
        let items = finder.leftovers(for: .init(bundleIDs: ["com.acme.Notes"], name: "Notes", teamID: "ABCDE12345"))
        let selected = items.filter(\.autoSelect).map { $0.url.deletingLastPathComponent().lastPathComponent }
        #expect(selected == ["Caches"])
        #expect(items.filter { $0.url.path.contains("/Containers/") || $0.url.path.contains("Application Support") }
            .allSatisfy { $0.risk == .high })
    }

    @Test func filesOfSiblingAppsAreLeftAlone() throws {
        let home = try FakeHome(); defer { home.remove() }
        try home.file("Library/Preferences/com.google.Chrome.plist", bytes: 4096)
        try home.file("Library/Preferences/com.google.Chrome.canary.plist", bytes: 4096)
        try home.file("Library/Caches/com.google.Chrome.canary/x", bytes: 4096)
        let finder = LeftoverFinder(home: home.url, systemLibrary: home.url.appendingPathComponent("NoSystem"))
        let identity = LeftoverFinder.Identity(bundleIDs: ["com.google.Chrome"], name: "Google Chrome", teamID: nil)
        let names = finder.leftovers(for: identity, otherAppIDs: ["com.google.Chrome.canary"]).map(\.url.lastPathComponent)
        #expect(names == ["com.google.Chrome.plist"])
        // Without the other app installed, its files still count as the app's.
        #expect(finder.leftovers(for: identity).count == 3)
    }

    @Test func orphanDetectionHelpers() {
        #expect(OrphanLeftoversModule.bundleIDLike("com.vendor.App.plist") == "com.vendor.app")
        #expect(OrphanLeftoversModule.bundleIDLike("com.apple.Safari") == nil)
        #expect(OrphanLeftoversModule.bundleIDLike("Google") == nil)
        #expect(OrphanLeftoversModule.bundleIDLike("com.foo") == nil)
        let known: Set<String> = ["com.vendor.app"]
        #expect(OrphanLeftoversModule.isOwned("com.vendor.app.helper", known: known))
        #expect(OrphanLeftoversModule.isOwned("com.vendor.shared", known: ["com.vendor.shared.app"]))
        #expect(OrphanLeftoversModule.isOwned("com.other.app", known: known) == false)
    }

    @Test func versionComparison() {
        #expect(Version.isNewer("1.10", than: "1.9"))
        #expect(Version.isNewer("2.0.1", than: "2.0"))
        #expect(!Version.isNewer("2.0", than: "2.0"))
        #expect(Version.isNewer("v3.1", than: "3.0.9 (1234)"))
        #expect(!Version.isNewer("", than: "1.0"))
    }

    @Test func appcastPicksNewestCompatibleItem() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><title>2.0</title><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://x/2.zip" sparkle:version="200" sparkle:shortVersionString="2.0"/></item>
        <item><title>1.5</title><sparkle:releaseNotesLink>https://x/notes</sparkle:releaseNotesLink>
          <enclosure url="https://x/1.5.zip" sparkle:version="150" sparkle:shortVersionString="1.5"/></item>
        <item><title>1.4</title><enclosure url="https://x/1.4.zip" sparkle:version="140"/></item>
        </channel></rss>
        """
        let items = Appcast.parse(Data(xml.utf8))
        #expect(items.count == 3)
        let newest = Appcast.newest(items, systemVersion: "27.0")
        #expect(newest?.shortVersion == "1.5")
        #expect(newest?.releaseNotes?.absoluteString == "https://x/notes")
    }

    @Test func storeAndBrewParsing() {
        let lookup = #"{"resultCount":1,"results":[{"bundleId":"com.x.app","version":"3.2","trackViewUrl":"https://apps.apple.com/app/id1"}]}"#
        #expect(UpdateChecker.parseLookup(Data(lookup.utf8))["com.x.app"]?.version == "3.2")

        let outdated = #"{"formulae":[],"casks":[{"name":"firefox","installed_versions":["120.0"],"current_version":"121.0"}]}"#
        #expect(UpdateChecker.parseBrewOutdated(Data(outdated.utf8)).first?.version == "121.0")

        let info = #"{"casks":[{"token":"firefox","artifacts":[{"app":["Firefox.app"]},{"zap":[]}]}]}"#
        #expect(UpdateChecker.parseBrewAppNames(Data(info.utf8))["firefox"] == ["Firefox.app"])
    }
}
