import Foundation
import MaestraleCore
import Testing
@testable import MaestraleModules

/// A throwaway home folder with the layout the checks expect.
struct TempHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @discardableResult
    func executable(_ relative: String) throws -> URL {
        let file = try write(relative, "#!/bin/sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    func launchAgent(label: String, program: String, extra: String = "") throws -> URL {
        try write("Library/LaunchAgents/\(label).plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(label)</string>
        <key>ProgramArguments</key><array><string>\(program)</string></array>
        \(extra)
        </dict></plist>
        """)
    }

    /// Only the launch items in this home, so the Mac's own agents do not interfere.
    func context(signatures: FakeSignatures = FakeSignatures(), commands: FakeCommands = FakeCommands(),
                 trustedTeams: Set<String> = []) -> CheckContext {
        let items = LaunchItemsScanner(home: url).scan().filter { $0.plist.path.hasPrefix(url.path) }
        return CheckContext(home: url, signatures: signatures, commands: commands, launchItems: items, trustedTeams: trustedTeams)
    }
}

@Suite struct LaunchItemsCheckTests {
    @Test func programInTemporaryFolderIsDanger() throws {
        let home = try TempHome(); defer { home.remove() }
        let evil = URL(fileURLWithPath: "/tmp/mc-test-\(UUID().uuidString)/updater")
        try FileManager.default.createDirectory(at: evil.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: evil, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: evil.deletingLastPathComponent()) }
        try home.launchAgent(label: "com.vendor.updater", program: evil.path)

        let findings = LaunchItemsCheck().run(home.context(signatures: FakeSignatures(fallback: .unsigned)))
        let finding = try #require(findings.first)
        #expect(finding.severity == .danger)
        #expect(finding.category == .persistence)
        #expect(finding.reasons.contains("Avviato da una cartella temporanea o condivisa"))
        #expect(finding.reasons.contains("Il programma non è firmato"))
        #expect(finding.action == .removeLaunchItem)
        #expect(finding.launchItem?.label == "com.vendor.updater")
        #expect(finding.evidence.contains("Label: com.vendor.updater"))
    }

    @Test func appleLabelOutsideSystemIsDanger() throws {
        let home = try TempHome(); defer { home.remove() }
        let program = try home.executable("Library/Application Support/Helper/agent")
        try home.launchAgent(label: "com.apple.softwareupdated", program: program.path)

        let findings = LaunchItemsCheck().run(home.context(signatures: FakeSignatures(fallback: .apple)))
        let finding = try #require(findings.first)
        #expect(finding.severity == .danger)
        #expect(finding.reasons == ["Si spaccia per un componente Apple"])
    }

    @Test func hiddenFolderAndAdHocSignatureAreWarnings() throws {
        let home = try TempHome(); defer { home.remove() }
        let program = try home.executable("Library/Application Support/.cache/sync")
        try home.launchAgent(label: "com.vendor.sync", program: program.path)

        let findings = LaunchItemsCheck().run(home.context(signatures: FakeSignatures(fallback: .adHoc)))
        let finding = try #require(findings.first)
        #expect(finding.severity == .warning)
        #expect(finding.reasons.contains("Avviato da una cartella nascosta"))
        #expect(finding.reasons.contains("Firma ad-hoc: nessuno sviluppatore identificato"))
    }

    @Test func dyldInsertionIsDanger() throws {
        let home = try TempHome(); defer { home.remove() }
        let program = try home.executable("Library/Application Support/Vendor/agent")
        try home.launchAgent(label: "com.vendor.agent", program: program.path, extra: """
        <key>EnvironmentVariables</key><dict><key>DYLD_INSERT_LIBRARIES</key><string>/Users/Shared/lib.dylib</string></dict>
        """)

        let findings = LaunchItemsCheck().run(home.context(signatures: FakeSignatures(fallback: .signed(team: "ABC123", notarized: true))))
        let finding = try #require(findings.first)
        #expect(finding.severity == .danger)
        #expect(finding.reasons == ["Inietta una libreria in altri programmi (DYLD_INSERT_LIBRARIES)"])
        #expect(finding.evidence.contains("DYLD_INSERT_LIBRARIES = /Users/Shared/lib.dylib"))
        #expect(finding.team == "ABC123")
    }

    @Test func notarizedProgramInNormalPlaceIsSilent() throws {
        let home = try TempHome(); defer { home.remove() }
        let program = try home.executable("Library/Application Support/Vendor/agent")
        try home.launchAgent(label: "com.vendor.agent", program: program.path)
        let findings = LaunchItemsCheck().run(home.context(signatures: FakeSignatures(fallback: .signed(team: "ABC123", notarized: true))))
        #expect(findings.isEmpty)
    }

    @Test func brokenItemsAreLeftToSystemJunk() throws {
        let home = try TempHome(); defer { home.remove() }
        try home.launchAgent(label: "com.vendor.gone", program: home.url.appendingPathComponent("missing").path)
        #expect(LaunchItemsCheck().run(home.context(signatures: FakeSignatures(fallback: .unsigned))).isEmpty)
    }

    @Test func packageManagerProgramsAreInformational() {
        let (reasons, severity) = CodeSignature.unsigned.assess(path: "/opt/homebrew/opt/postgresql/bin/postgres")
        #expect(severity == .info)
        #expect(reasons.first?.contains("gestore di pacchetti") == true)
        #expect(CodeSignature.unsigned.assess(path: "/Users/x/bin/tool").severity == .warning)
        #expect(CodeSignature.invalid.assess(path: "/Users/x/bin/tool").severity == .danger)
        #expect(CodeSignature.signed(team: "T", notarized: false).assess(path: "/Applications/A.app/x").severity == .warning)
        #expect(CodeSignature.signed(team: "T", notarized: true).assess(path: "/Applications/A.app/x").reasons.isEmpty)
    }

    @Test func locations() {
        #expect(KnownLocations.kind(of: "/tmp/x/y") == .temporary)
        #expect(KnownLocations.kind(of: "/private/var/tmp/y") == .temporary)
        #expect(KnownLocations.kind(of: "/Users/Shared/y") == .temporary)
        #expect(KnownLocations.kind(of: "/Users/x/.config/y/bin") == .hidden)
        #expect(KnownLocations.kind(of: "/Applications/X.app/Contents/.hidden/bin") == .normal)
        #expect(KnownLocations.kind(of: "/Applications/X.app/Contents/MacOS/X") == .normal)
        #expect(KnownLocations.isSystem("/usr/libexec/x"))
        #expect(!KnownLocations.isSystem("/Library/LaunchAgents/x"))
    }
}

@Suite struct AppsSignatureCheckTests {
    func fakeApp(in folder: URL, _ name: String) throws -> URL {
        let app = folder.appendingPathComponent("\(name).app/Contents/MacOS")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "bin".write(to: app.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return folder.appendingPathComponent("\(name).app")
    }

    @Test func unsignedAndTamperedAppsAreWarnings() throws {
        let home = try TempHome(); defer { home.remove() }
        let apps = home.url.appendingPathComponent("Applications")
        let unsigned = try fakeApp(in: apps, "Unsigned")
        let tampered = try fakeApp(in: apps, "Tampered")
        let fine = try fakeApp(in: apps, "Fine")
        let signatures = FakeSignatures([unsigned.path: .unsigned, tampered.path: .invalid, fine.path: .signed(team: "T", notarized: true)])

        let findings = AppsSignatureCheck(folders: [apps]).run(home.context(signatures: signatures))
        #expect(findings.count == 2)
        #expect(findings.first { $0.path == unsigned }?.reasons == ["App non firmata"])
        #expect(findings.first { $0.path == tampered }?.severity == .warning)
        #expect(findings.allSatisfy { $0.category == .application && $0.action == .trash })
    }
}

@Suite struct BrowserExtensionsCheckTests {
    func chromeExtension(_ home: TempHome, id: String, permissions: [String], fromStore: Bool, name: String = "Ext") throws {
        let base = "Library/Application Support/Google/Chrome/Default"
        let permissionsJSON = permissions.map { "\"\($0)\"" }.joined(separator: ",")
        try home.write("\(base)/Extensions/\(id)/1.0_0/manifest.json",
                       #"{"name":"\#(name)","version":"1.0","permissions":[\#(permissionsJSON)]}"#)
        let preferences = home.url.appendingPathComponent("\(base)/Preferences")
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: preferences), let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var extensions = root["extensions"] as? [String: Any] ?? [:]
        var settings = extensions["settings"] as? [String: Any] ?? [:]
        settings[id] = ["from_webstore": fromStore, "creation_flags": fromStore ? 9 : 1]
        extensions["settings"] = settings
        root["extensions"] = extensions
        try JSONSerialization.data(withJSONObject: root).write(to: preferences)
    }

    @Test func allSitesFromStoreIsInfoAndSideloadIsWarning() throws {
        let home = try TempHome(); defer { home.remove() }
        try chromeExtension(home, id: "aaaa", permissions: ["<all_urls>", "tabs"], fromStore: true, name: "Blocker")
        try chromeExtension(home, id: "bbbb", permissions: ["storage"], fromStore: false, name: "Sideloaded")
        try chromeExtension(home, id: "cccc", permissions: ["storage"], fromStore: true, name: "Quiet")

        let findings = BrowserExtensionsCheck().run(home.context())
        #expect(findings.count == 2)
        let blocker = try #require(findings.first { $0.title == "Google Chrome: Blocker" })
        #expect(blocker.severity == .info)
        #expect(blocker.reasons == ["Può leggere e modificare tutti i siti"])
        #expect(blocker.evidence.contains("Permesso: <all_urls>"))
        let sideloaded = try #require(findings.first { $0.title == "Google Chrome: Sideloaded" })
        #expect(sideloaded.severity == .warning)
        #expect(sideloaded.reasons == ["Installazione dallo store non verificata"])
    }

    @Test func updateURLInManifestDoesNotCount() throws {
        let home = try TempHome(); defer { home.remove() }
        let base = "Library/Application Support/Google/Chrome/Default"
        try home.write("\(base)/Extensions/dddd/2.0_0/manifest.json",
                       #"{"name":"Fake","version":"2.0","update_url":"https://clients2.google.com/service/update2/crx","permissions":["storage"]}"#)
        try home.write("\(base)/Preferences", "{}")
        let findings = BrowserExtensionsCheck().run(home.context())
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .warning)
    }

    @Test func firefoxSideloadedAddonIsWarning() throws {
        let home = try TempHome(); defer { home.remove() }
        try home.write("Library/Application Support/Firefox/Profiles/abc.default/extensions.json", """
        {"addons":[
          {"id":"ublock@raymondhill.net","type":"extension","active":true,"location":"app-profile","signedState":2,
           "defaultLocale":{"name":"uBlock Origin"},"userPermissions":{"origins":["<all_urls>"]},"path":"/x/ublock.xpi"},
          {"id":"evil@x","type":"extension","active":true,"location":"app-system-share","signedState":0,
           "defaultLocale":{"name":"Evil"},"userPermissions":{"origins":[]},"path":"/x/evil.xpi"},
          {"id":"builtin@mozilla.org","type":"extension","active":true,"location":"app-builtin","signedState":0}
        ]}
        """)
        let findings = BrowserExtensionsCheck().run(home.context())
        #expect(findings.count == 2)
        #expect(findings.first { $0.title == "Firefox: uBlock Origin" }?.severity == .info)
        let evil = try #require(findings.first { $0.title == "Firefox: Evil" })
        #expect(evil.severity == .warning)
        #expect(evil.reasons.contains("Non firmata da Mozilla"))
    }
}

@Suite struct ProtectionScannerTests {
    struct StaticCheck: ProtectionCheck {
        let id: String
        let title = "static"
        let requirement: CheckRequirement
        let findings: [Finding]
        func run(_ context: CheckContext) -> [Finding] { findings }
    }

    func finding(_ key: String, _ severity: Finding.Severity, team: String? = nil) -> Finding {
        Finding(category: .persistence, key: key, severity: severity, title: key, reasons: ["r"], team: team)
    }

    @Test func sortsBySeverityDropsDuplicatesAndSkipsAdminChecksWithoutEvidence() throws {
        let home = try TempHome(); defer { home.remove() }
        let scanner = ProtectionScanner(context: home.context(), checks: [
            StaticCheck(id: "a", requirement: .none, findings: [finding("x", .info), finding("y", .danger)]),
            StaticCheck(id: "b", requirement: .none, findings: [finding("x", .info), finding("z", .warning)]),
            StaticCheck(id: "c", requirement: .admin, findings: [finding("root", .danger)]),
        ])
        let findings = scanner.scan()
        #expect(findings.map(\.title) == ["y", "z", "x"])
    }

    @Test func trustedTeamsHideWarningsButNotDangers() throws {
        let home = try TempHome(); defer { home.remove() }
        let scanner = ProtectionScanner(context: home.context(trustedTeams: ["TRUST"]), checks: [
            StaticCheck(id: "a", requirement: .none, findings: [
                finding("w", .warning, team: "TRUST"), finding("d", .danger, team: "TRUST"), finding("o", .warning, team: "OTHER"),
            ]),
        ])
        #expect(scanner.scan().map(\.title) == ["d", "o"])
    }

    @Test func realSignaturesRecognizeApple() {
        let signatures = CachedSignatures()
        #expect(signatures.signature(of: URL(fileURLWithPath: "/bin/ls")) == .apple)
        #expect(signatures.signature(of: URL(fileURLWithPath: "/bin/ls")) == .apple)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)")
        try? "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(signatures.signature(of: file) == .unsigned)
    }

    @Test func fakeCommandsKeyOnToolAndArguments() {
        let commands = FakeCommands(["/usr/sbin/spctl --status": "assessments enabled\n"])
        #expect(commands.run("/usr/sbin/spctl", ["--status"]) == "assessments enabled\n")
        #expect(commands.run("/usr/sbin/spctl", ["--other"]) == "")
        let status = MalwareScanner(commands: FakeCommands([
            "/usr/sbin/spctl --status": "assessments disabled",
            "/usr/bin/csrutil status": "System Integrity Protection status: enabled.",
            "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate": "Firewall is enabled. (State = 1)",
        ])).protectionStatus()
        #expect(status.gatekeeperEnabled == false)
        #expect(status.sipEnabled == true)
        #expect(status.firewallEnabled == true)
    }
}

@Suite struct ProtectionBaselineTests {
    @Test func firstScanIsNeverNewThenNewIdsAreMarked() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-\(UUID().uuidString).json")
        let baseline = ProtectionBaseline(fileURL: file); defer { baseline.reset() }
        let a = Finding(category: .persistence, key: "a", severity: .info, title: "a", reasons: [])
        let b = Finding(category: .persistence, key: "b", severity: .info, title: "b", reasons: [])
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)

        let first = baseline.apply([a], now: day1)
        #expect(first.map(\.isNew) == [false])
        #expect(first.first?.firstSeen == day1)

        let second = baseline.apply([a, b], now: day1.addingTimeInterval(86_400))
        #expect(second.map(\.isNew) == [false, true])
        #expect(second.first?.firstSeen == day1)
        #expect(second.last?.firstSeen == day1.addingTimeInterval(86_400))

        // Seen again a week later: still known, not new.
        let third = baseline.apply([b], now: day1.addingTimeInterval(8 * 86_400))
        #expect(third.map(\.isNew) == [false])

        // After 90 days away, "a" counts as new again.
        let fourth = baseline.apply([a], now: day1.addingTimeInterval(100 * 86_400))
        #expect(fourth.map(\.isNew) == [true])
    }
}
