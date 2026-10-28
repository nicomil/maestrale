import Foundation
import MaestraleCore
import Testing
@testable import MaestraleModules

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

    /// A stand-in for mshelper: a script that prints its arguments.
    func fakeHelper() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-helper-\(UUID().uuidString)")
        try "#!/bin/sh\necho \"ran $*\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func sh(_ command: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    func someSystemCache() -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/Library/Caches")) ?? []
        return entries.first(where: {
            FileManager.default.fileExists(atPath: "/Library/Caches/\($0)")
                && !SafeRemover.isSystemProtected(URL(fileURLWithPath: "/Library/Caches/\($0)"))
                && PinnedFileSystem.isPlainName($0)
        }).map { URL(fileURLWithPath: "/Library/Caches/\($0)") }
    }

    /// Files are handed to the helper as "<canonical folder> <name>", never as a
    /// full path for rm or mv.
    @Test func systemFilesGoThroughTheHelper() throws {
        guard let source = someSystemCache() else { return }
        let helper = try fakeHelper(); defer { try? FileManager.default.removeItem(at: helper) }
        let runner = AdminRunner(log: nil, helper: helper)
        let name = AdminRunner.shellQuote(source.lastPathComponent)

        let remove = try runner.command(for: .remove([source]))
        #expect(remove.contains("'remove' '/Library/Caches' \(name)"))
        #expect(!remove.contains("/bin/rm -rf -- '/Library") && !remove.contains("/bin/mv"))

        let trash = FileManager.default.temporaryDirectory.appendingPathComponent("trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: trash) }
        let move = try runner.command(for: .moveToTrash([source]), trash: trash)
        let realTrash = try #require(AdminRunner.realPath(trash))
        #expect(move.contains("'trash' \(AdminRunner.shellQuote(realTrash)) '\(getuid())' '/Library/Caches' \(name)"))

        #expect(throws: AdminError.self) { try runner.command(for: .moveToTrash([URL(fileURLWithPath: "/etc/hosts")]), trash: trash) }
        #expect(throws: AdminError.self) {
            try runner.command(for: .moveToTrash([source]), trash: trash.appendingPathComponent("missing"))
        }
        // Without the helper nothing is run as root.
        #expect(throws: AdminError.self) { try AdminRunner(log: nil, helper: nil).command(for: .remove([source])) }
    }

    /// The helper is copied where only the caller can write and checked against
    /// the hash taken when the command was built: a swapped helper never runs.
    @Test func swappedHelperNeverRuns() throws {
        let helper = try fakeHelper(); defer { try? FileManager.default.removeItem(at: helper) }
        let command = try AdminRunner(log: nil, helper: helper).helperCommand(["remove", "/Library/Caches", "x y"])
        let first = try sh(command)
        #expect(first.status == 0)
        #expect(first.output == "ran remove /Library/Caches x y\n")

        try "#!/bin/sh\necho evil\n".write(to: helper, atomically: true, encoding: .utf8)
        let second = try sh(command)
        #expect(second.status != 0)
        #expect(!second.output.contains("evil"))
    }

    @Test func helperReportIsParsed() {
        let (done, failed) = AdminRunner.parseHelperReport("ok\t/a/b\t/t/b 2\nerr\t/a/c\tprotetto da SIP\nok\t/a/d\n")
        #expect(done == ["/a/b", "/a/d"])
        #expect(failed == ["/a/c: protetto da SIP"])
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
        let helper = try fakeHelper(); defer { try? FileManager.default.removeItem(at: helper) }
        let runner = AdminRunner(log: nil, helper: helper)
        let daemons = (try? FileManager.default.contentsOfDirectory(atPath: "/Library/LaunchDaemons")) ?? []
        if let name = daemons.first(where: { $0.hasSuffix(".plist") }) {
            let command = try runner.command(for: .removeDaemon(label: "com.vendor.d",
                                                                plist: URL(fileURLWithPath: "/Library/LaunchDaemons/\(name)")))
            let stop = try #require(command.range(of: "launchctl print system/com.vendor.d"))
            let move = try #require(command.range(of: "'trash'"))
            #expect(stop.lowerBound < move.lowerBound)
        }
        #expect(throws: AdminError.self) {
            try runner.command(for: .removeDaemon(label: "com.x", plist: URL(fileURLWithPath: "/Library/LaunchAgents/x.plist")))
        }
        #expect(throws: AdminError.self) {
            try runner.command(for: .removeDaemon(label: "x; reboot", plist: URL(fileURLWithPath: "/Library/LaunchDaemons/x.plist")))
        }
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
        let backup = try #require(backups.first { $0.hasPrefix("Maestrale, copia di Google Chrome Default History") })
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

    @Test func maintenanceSummariesTellWhatChanged() {
        let listing = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-10-28-101500.local
        com.apple.TimeMachine.2026-10-28-111500.local
        """
        #expect(MaintenanceTask.parseSnapshots(listing).count == 2)
        #expect(MaintenanceTask.parseSnapshots("Snapshots for disk /:\n").isEmpty)
        #expect(MaintenanceTask.ramSummary(before: 3_000_000_000, after: 500_000_000).contains("liberati"))
        #expect(MaintenanceTask.ramSummary(before: 500_000_000, after: 490_000_000).contains("quasi nulla"))
        #expect(MaintenanceTask.snapshotsSummary(before: 2, after: 0, freed: 1_000_000_000).hasPrefix("Eliminate 2 istantanee su 2"))
        #expect(MaintenanceTask.snapshotsSummary(before: 2, after: 2, freed: 0).contains("Nessuna istantanea eliminata"))
    }

    @Test func maintenanceTasksHaveAdminOperationsExceptMail() {
        for task in MaintenanceTask.Kind.allCases.map(MaintenanceTask.init(kind:)) {
            #expect((task.adminOperation == nil) == (task.kind == .speedUpMail))
        }
    }
}
