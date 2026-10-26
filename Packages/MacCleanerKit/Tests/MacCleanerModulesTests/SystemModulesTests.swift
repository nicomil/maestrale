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
        #expect(command.hasPrefix("( cd -P -- '/Library/Caches' && [ \"$(pwd -P)\" = '/Library/Caches' ] "))
        #expect(command.hasSuffix("/bin/rm -rf -- " + AdminRunner.shellQuote("./\(name)") + " )"))
    }

    @Test func adminMoveToTrashKeepsItemsRestorable() throws {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/Library/Caches")) ?? []
        guard let name = entries.first(where: {
            FileManager.default.fileExists(atPath: "/Library/Caches/\($0)")
                && !SafeRemover.isSystemProtected(URL(fileURLWithPath: "/Library/Caches/\($0)"))
        }) else { return }
        let trash = FileManager.default.temporaryDirectory.appendingPathComponent("trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: trash) }
        // A file with the same name already in the Trash must not be overwritten.
        FileManager.default.createFile(atPath: trash.appendingPathComponent(name).path, contents: Data())

        let source = URL(fileURLWithPath: "/Library/Caches/\(name)")
        let command = try AdminRunner(log: nil).command(for: .moveToTrash([source]), trash: trash)
        let ext = source.pathExtension
        let renamed = ext.isEmpty ? "\(name) 2" : "\(source.deletingPathExtension().lastPathComponent) 2.\(ext)"
        let realTrash = try #require(AdminRunner.realPath(trash))
        #expect(command.contains("/bin/mv -n -- " + AdminRunner.shellQuote("./\(name)") + " "
                + AdminRunner.shellQuote(realTrash + "/" + renamed)))
        #expect(!command.contains("rm "))

        #expect(throws: AdminError.self) {
            try AdminRunner(log: nil).command(for: .moveToTrash([URL(fileURLWithPath: "/etc/hosts")]), trash: trash)
        }
        #expect(throws: AdminError.self) {
            try AdminRunner(log: nil).command(for: .moveToTrash([source]), trash: trash.appendingPathComponent("missing"))
        }
    }

    /// The folder of an item is swapped for a symlink between the check and the
    /// command (while the password prompt is open): nothing outside is touched.
    @Test func folderSwappedAfterTheCheckIsRefused() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Caches/vendor")
        let elsewhere = base.appendingPathComponent("Precious")
        for dir in [folder, elsewhere] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("junk").path, contents: Data())
        let precious = elsewhere.appendingPathComponent("junk")
        FileManager.default.createFile(atPath: precious.path, contents: Data("keep".utf8))

        let item = folder.appendingPathComponent("junk")
        let remove = try AdminRunner.insideFolder(of: item) { "/bin/rm -rf -- \($0)" }
        // The swap.
        try FileManager.default.moveItem(at: folder, to: base.appendingPathComponent("Caches/vendor-old"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", remove]
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        shell.waitUntilExit()
        #expect(shell.terminationStatus != 0)
        #expect(FileManager.default.fileExists(atPath: precious.path))

        // Without the swap the same command works.
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: base.appendingPathComponent("Caches/vendor-old"), to: folder)
        let again = Process()
        again.executableURL = URL(fileURLWithPath: "/bin/sh")
        again.arguments = ["-c", remove]
        try again.run()
        again.waitUntilExit()
        #expect(again.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: item.path))
    }

    /// Agents in /Library/LaunchAgents run in the user's session, not in "system".
    @Test func launchItemsAreStoppedInTheirOwnDomain() throws {
        func item(_ domain: LaunchItem.Domain) -> LaunchItem {
            LaunchItem(plist: URL(fileURLWithPath: "/tmp/x.plist"), label: "com.x", program: nil, domain: domain,
                       isDisabled: false, isBroken: false, ownerApp: nil)
        }
        #expect(item(.userAgent).service == "gui/\(getuid())/com.x")
        #expect(item(.systemAgent).service == "gui/\(getuid())/com.x")
        #expect(item(.systemDaemon).service == "system/com.x")
        #expect(!item(.systemAgent).stopNeedsAdmin && item(.systemDaemon).stopNeedsAdmin)
        #expect(LaunchItemsScanner().isLoaded(item(.userAgent)) == false)

        // A daemon's plist is moved only after launchd let it go.
        let runner = AdminRunner(log: nil)
        let daemons = (try? FileManager.default.contentsOfDirectory(atPath: "/Library/LaunchDaemons")) ?? []
        if let name = daemons.first(where: { $0.hasSuffix(".plist") }) {
            let command = try runner.command(for: .removeDaemon(label: "com.vendor.d",
                                                                plist: URL(fileURLWithPath: "/Library/LaunchDaemons/\(name)")))
            let stop = try #require(command.range(of: "launchctl print system/com.vendor.d"))
            let move = try #require(command.range(of: "/bin/mv -n"))
            #expect(stop.lowerBound < move.lowerBound)
        }
        #expect(throws: AdminError.self) {
            try runner.command(for: .removeDaemon(label: "com.x", plist: URL(fileURLWithPath: "/Library/LaunchAgents/x.plist")))
        }
        #expect(throws: AdminError.self) {
            try runner.command(for: .removeDaemon(label: "x; reboot", plist: URL(fileURLWithPath: "/Library/LaunchDaemons/x.plist")))
        }
    }

    @Test func trashDestinationsAreUniqueWithinABatch() {
        let trash = URL(fileURLWithPath: "/nonexistent-trash")
        let names = AdminRunner.trashDestinations(
            [URL(fileURLWithPath: "/Library/Logs/a.log"), URL(fileURLWithPath: "/private/var/log/a.log"),
             URL(fileURLWithPath: "/Library/Caches/dir")], trash: trash).map(\.destination.lastPathComponent)
        #expect(names == ["a.log", "a 2.log", "dir"])
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

        // A copy of the database, with the history still inside, is in the Trash.
        let trash = home.url.appendingPathComponent(".Trash")
        let backups = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        let backup = try #require(backups.first { $0.hasPrefix("MacCleaner, copia di Google Chrome Default History") })
        let copy = try #require(SQLiteDB(url: trash.appendingPathComponent(backup).appendingPathComponent("History"),
                                         readOnly: true))
        #expect(copy.count("urls") == 3)
    }

    /// A profile reached through a symlink: the backup must hold the data,
    /// not a second link to the database that is about to be emptied.
    @Test func backupOfSymlinkedDatabaseIsARealCopy() async throws {
        let home = try FakeHome(); defer { home.remove() }
        let elsewhere = home.url.appendingPathComponent("External/Default")
        try makeDB(elsewhere.appendingPathComponent("History"), [
            "CREATE TABLE urls(id INTEGER)", "CREATE TABLE visits(id INTEGER)",
            "CREATE TABLE keyword_search_terms(id INTEGER)", "CREATE TABLE segments(id INTEGER)",
            "CREATE TABLE segment_usage(id INTEGER)", "INSERT INTO urls VALUES (1),(2),(3)",
        ])
        let chrome = home.url.appendingPathComponent("Library/Application Support/Google/Chrome")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: chrome.appendingPathComponent("Default"), withDestinationURL: elsewhere)

        let scanner = PrivacyScanner(home: home.url)
        let history = try #require(scanner.scan().first { $0.owner == "Google Chrome" && $0.kind == .history })
        try await scanner.clean(history)

        let trash = home.url.appendingPathComponent(".Trash")
        let folder = try #require(try FileManager.default.contentsOfDirectory(atPath: trash.path).first)
        let copy = trash.appendingPathComponent(folder).appendingPathComponent("History")
        let values = try copy.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        #expect(values.isSymbolicLink == false && values.isRegularFile == true)
        #expect(try #require(SQLiteDB(url: copy, readOnly: true)).count("urls") == 3)
    }

    /// Rows still in the "-wal" file are counted and end up in the backup.
    @Test func recentChangesInTheWALAreSeen() async throws {
        let home = try FakeHome(); defer { home.remove() }
        let url = home.url.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Network/Cookies")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = try #require(SQLiteDB(url: url, readOnly: false))
        #expect(writer.text("PRAGMA journal_mode=WAL") == "wal")
        #expect(writer.execute("PRAGMA wal_autocheckpoint=0"))
        #expect(writer.execute("CREATE TABLE cookies(id INTEGER)"))
        #expect(writer.execute("INSERT INTO cookies VALUES (1),(2),(3)"))
        // The writer stays open, so the rows are only in Cookies-wal.
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))

        let scanner = PrivacyScanner(home: home.url)
        let cookies = try #require(scanner.scan().first { $0.kind == .cookies })
        #expect(cookies.count == 3)
        let folder = try scanner.backupToTrash(url, for: cookies)
        #expect(try #require(SQLiteDB(url: folder.appendingPathComponent("Cookies"), readOnly: true)).count("cookies") == 3)
        withExtendedLifetime(writer) {}
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
