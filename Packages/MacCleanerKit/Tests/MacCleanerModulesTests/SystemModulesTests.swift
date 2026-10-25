import Foundation
import MacCleanerCore
import Testing
@testable import MacCleanerModules

@Suite struct SystemModulesTests {
    @Test func shellQuotingNeutralizesInjection() {
        #expect(AdminRunner.shellQuote("a b") == "'a b'")
        #expect(AdminRunner.shellQuote("x'; rm -rf / #") == #"'x'\''; rm -rf / #'"#)
        #expect(AdminRunner.appleScriptString(#"say "hi" \ ok"#) == #""say \"hi\" \\ ok""#)
    }

    @Test func adminRemoveRefusesPathsOutsideSystemRoots() throws {
        let runner = AdminRunner(log: nil)
        #expect(throws: AdminError.self) { try runner.command(for: .remove([URL(fileURLWithPath: "/etc/hosts")])) }
        #expect(throws: AdminError.self) { try runner.command(for: .remove([URL(fileURLWithPath: "/Library/Caches")])) }
        #expect(throws: AdminError.self) { try runner.command(for: .remove([])) }
        #expect(throws: AdminError.self) { try runner.command(for: .bootoutDaemon(label: "x; reboot")) }
        #expect(try runner.command(for: .freeRAM) == "/usr/sbin/purge")
    }

    @Test func adminRemoveQuotesValidSystemPaths() throws {
        // /Library/Caches always has some entry on a real Mac.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/Library/Caches")) ?? []
        guard let name = entries.first(where: {
            FileManager.default.fileExists(atPath: "/Library/Caches/\($0)")
                && !SafeRemover.isSystemProtected(URL(fileURLWithPath: "/Library/Caches/\($0)"))
        }) else { return }
        let command = try AdminRunner(log: nil).command(for: .remove([URL(fileURLWithPath: "/Library/Caches/\(name)")]))
        #expect(command == "/bin/rm -rf -- " + AdminRunner.shellQuote("/Library/Caches/\(name)"))
    }

    func makeDB(_ url: URL, _ statements: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let db = try #require(SQLiteDB(url: url, readOnly: false))
        for sql in statements { #expect(db.execute(sql), "\(sql)") }
    }

    @Test func chromeHistoryAndCookiesAreFoundAndCleaned() async throws {
        let home = try FakeHome(); defer { home.remove() }
        let profile = home.url.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
        try makeDB(profile.appendingPathComponent("History"), [
            "CREATE TABLE urls(id INTEGER)", "CREATE TABLE visits(id INTEGER)",
            "CREATE TABLE keyword_search_terms(id INTEGER)", "CREATE TABLE segments(id INTEGER)",
            "CREATE TABLE segment_usage(id INTEGER)", "CREATE TABLE downloads(id INTEGER)",
            "CREATE TABLE downloads_url_chains(id INTEGER)",
            "INSERT INTO urls VALUES (1),(2),(3)", "INSERT INTO visits VALUES (1)",
        ])
        try makeDB(profile.appendingPathComponent("Network/Cookies"),
                   ["CREATE TABLE cookies(id INTEGER)", "INSERT INTO cookies VALUES (1),(2)"])

        let scanner = PrivacyScanner(home: home.url)
        let items = scanner.scan()
        let history = try #require(items.first { $0.owner == "Google Chrome" && $0.kind == .history })
        #expect(history.count == 3)
        #expect(items.contains { $0.kind == .cookies && $0.count == 2 })
        #expect(!items.contains { $0.kind == .downloads }) // empty tables are not listed

        // The test runner is not Chrome, so the browser counts as closed.
        try await scanner.clean(history)
        #expect(!scanner.scan().contains { $0.owner == "Google Chrome" && $0.kind == .history })
    }

    @Test func firefoxKeepsBookmarkedPlaces() async throws {
        let home = try FakeHome(); defer { home.remove() }
        let places = home.url.appendingPathComponent("Library/Application Support/Firefox/Profiles/abc.default/places.sqlite")
        try makeDB(places, [
            "CREATE TABLE moz_places(id INTEGER)", "CREATE TABLE moz_historyvisits(id INTEGER)",
            "CREATE TABLE moz_bookmarks(fk INTEGER)",
            "INSERT INTO moz_places VALUES (1),(2),(3)", "INSERT INTO moz_historyvisits VALUES (1),(2)",
            "INSERT INTO moz_bookmarks VALUES (2)",
        ])
        let scanner = PrivacyScanner(home: home.url)
        let history = try #require(scanner.scan().first { $0.owner == "Firefox" && $0.kind == .history })
        try await scanner.clean(history)
        let db = try #require(SQLiteDB(url: places, readOnly: true))
        #expect(db.count("moz_places") == 1)
        #expect(db.count("moz_historyvisits") == 0)
    }

    @Test func passwordsAreNeverPreselected() throws {
        let home = try FakeHome(); defer { home.remove() }
        try makeDB(home.url.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Login Data"),
                   ["CREATE TABLE logins(id INTEGER)", "INSERT INTO logins VALUES (1)"])
        let item = try #require(PrivacyScanner(home: home.url).scan().first { $0.kind == .passwords })
        #expect(!item.autoSelect)
    }

    @Test func brokenLaunchAgentsAreDetected() throws {
        let home = try FakeHome(); defer { home.remove() }
        let agents = home.url.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let broken: NSDictionary = ["Label": "com.gone.agent", "ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/gone"]]
        let fine: NSDictionary = ["Label": "com.ok.agent", "Program": "/bin/ls"]
        broken.write(to: agents.appendingPathComponent("com.gone.agent.plist"), atomically: true)
        fine.write(to: agents.appendingPathComponent("com.ok.agent.plist"), atomically: true)

        let items = LaunchItemsScanner(home: home.url).scan().filter { $0.domain == .userAgent }
        #expect(items.first { $0.label == "com.gone.agent" }?.isBroken == true)
        #expect(items.first { $0.label == "com.gone.agent" }?.ownerApp?.lastPathComponent == "Gone.app")
        #expect(items.first { $0.label == "com.ok.agent" }?.isBroken == false)
    }

    @Test func maintenanceTasksHaveAdminOperationsExceptMail() {
        for task in MaintenanceTask.Kind.allCases.map(MaintenanceTask.init(kind:)) {
            #expect((task.adminOperation == nil) == (task.kind == .speedUpMail))
        }
    }
}
