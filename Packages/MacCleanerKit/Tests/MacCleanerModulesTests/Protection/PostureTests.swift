import Foundation
import MacCleanerCore
import Testing
@testable import MacCleanerModules

@Suite struct PostureCheckTests {
    func preferences(_ files: [String: [String: Any]]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("prefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, dict) in files {
            (dict as NSDictionary).write(to: folder.appendingPathComponent(name), atomically: true)
        }
        return folder
    }

    @Test func weakSettingsBecomeFindingsWithLinks() throws {
        let home = try TempHome(); defer { home.remove() }
        let prefs = try preferences([
            "com.apple.SoftwareUpdate.plist": ["AutomaticCheckEnabled": 0, "ConfigDataInstall": 0, "CriticalUpdateInstall": 1],
            "com.apple.loginwindow.plist": ["autoLoginUser": "papa", "GuestEnabled": true],
            "safari.plist": ["AutoOpenSafeDownloads": true],
        ])
        defer { try? FileManager.default.removeItem(at: prefs) }
        let commands = FakeCommands([
            "/usr/bin/fdesetup status": "FileVault is Off.\n",
            "/usr/sbin/spctl --status": "assessments disabled\n",
            "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate": "Firewall is disabled. (State = 0)\n",
            "/bin/launchctl print system/com.openssh.sshd": "system/com.openssh.sshd = {\n\tstate = running\n}\n",
            "/bin/launchctl print system/com.apple.screensharing": "Bad request.\nCould not find service \"com.apple.screensharing\" in domain for system\n",
            "/usr/bin/dscl . -read /Groups/admin GroupMembership": "GroupMembership: root papa tecnico\n",
        ])
        let check = PostureCheck(systemPreferences: prefs, safariPreferences: prefs.appendingPathComponent("safari.plist"), currentUser: "papa")
        let findings = check.run(home.context(commands: commands))
        let byKey = Dictionary(uniqueKeysWithValues: findings.map { ($0.id, $0) })

        #expect(byKey["defense|filevault"]?.severity == .warning)
        #expect(byKey["defense|filevault"]?.action == .openSettings(SettingsLinks.fileVault))
        #expect(byKey["defense|gatekeeper"]?.severity == .danger)
        #expect(byKey["defense|firewall"]?.severity == .warning)
        #expect(byKey["defense|firewall-stealth"] == nil) // not checked when the firewall is off
        #expect(byKey["defense|updates-check"]?.severity == .warning)
        #expect(byKey["defense|updates-xprotect"]?.severity == .danger)
        #expect(byKey["defense|updates-critical"] == nil)
        #expect(byKey["defense|auto-login"]?.reasons == ["All'accensione entra papa senza password"])
        #expect(byKey["defense|guest"]?.severity == .info)
        #expect(byKey["defense|ssh"]?.evidence == ["state = running"])
        #expect(byKey["defense|screen-sharing"] == nil)
        #expect(byKey["defense|admins"]?.title == "Altri amministratori: tecnico")
        #expect(byKey["defense|safari-auto-open"]?.severity == .warning)
        #expect(findings.allSatisfy { $0.category == .defense })
    }

    @Test func healthyMacProducesNothing() throws {
        let home = try TempHome(); defer { home.remove() }
        let prefs = try preferences([
            "com.apple.SoftwareUpdate.plist": ["AutomaticCheckEnabled": 1, "ConfigDataInstall": 1],
            "com.apple.loginwindow.plist": ["GuestEnabled": 0],
            "safari.plist": ["AutoOpenSafeDownloads": false],
        ])
        defer { try? FileManager.default.removeItem(at: prefs) }
        let commands = FakeCommands([
            "/usr/bin/fdesetup status": "FileVault is On.\n",
            "/usr/sbin/spctl --status": "assessments enabled\n",
            "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate": "Firewall is enabled. (State = 1)\n",
            "/usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode": "Firewall stealth mode is on\n",
            "/usr/bin/dscl . -read /Groups/admin GroupMembership": "GroupMembership: root papa\n",
        ])
        let check = PostureCheck(systemPreferences: prefs, safariPreferences: prefs.appendingPathComponent("safari.plist"), currentUser: "papa")
        #expect(check.run(home.context(commands: commands)).isEmpty)
    }

    @Test func missingToolsAndFilesProduceNothing() throws {
        let home = try TempHome(); defer { home.remove() }
        let check = PostureCheck(systemPreferences: home.url.appendingPathComponent("nowhere"),
                                 safariPreferences: home.url.appendingPathComponent("nosafari.plist"), currentUser: "papa")
        #expect(check.run(home.context()).isEmpty)
    }
}

@Suite struct XProtectCheckTests {
    @Test func staleDefinitionsAreAWarning() throws {
        let home = try TempHome(); defer { home.remove() }
        let commands = FakeCommands(["/usr/bin/xprotect version": "Version: 5368 Installed: 2026-08-01 10:04:42 +0000\n"])
        let now = ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!
        let context = CheckContext(home: home.url, signatures: FakeSignatures(), commands: commands, now: now, launchItems: [])
        let findings = XProtectCheck(bundleInfo: home.url.appendingPathComponent("none.plist")).run(context)
        let stale = try #require(findings.first { $0.id == "defense|xprotect-stale" })
        #expect(stale.severity == .warning)
        #expect(stale.title == "Definizioni XProtect vecchie di 86 giorni")
        #expect(stale.action == .updateXProtect)
    }

    @Test func freshDefinitionsAreSilentAndBundleIsTheFallback() throws {
        let home = try TempHome(); defer { home.remove() }
        let info = try home.write("Info.plist", "")
        (["CFBundleShortVersionString": "5368"] as NSDictionary).write(to: info, atomically: true)
        let context = CheckContext(home: home.url, signatures: FakeSignatures(), commands: FakeCommands(), launchItems: [])
        let definitions = XProtectCheck.definitions(context: context, bundleInfo: info)
        #expect(definitions.version == "5368")
        #expect(definitions.installed != nil)
        #expect(XProtectCheck(bundleInfo: info).run(context).filter { $0.id.hasPrefix("defense|xprotect-stale") }.isEmpty)
    }

    @Test func remediatorEventsAreParsed() {
        let log = """
        Timestamp               Ty Process[PID:TID]
        2026-10-20 06:14:55.946 Df XProtectRemediatorSnowBeagle[20246:3e3aa3] [com.apple.XProtectFramework.PluginAPI:default] {"caused_by":[],"status_message":"","execution_duration":1.2,"module":"XProtectRemediatorSnowBeagle","status_code":0,"type":"XPEvent.structured","subject":""}
        2026-10-21 06:14:55.946 Df XProtectRemediatorAdload[20250:3e3aa3] [com.apple.XProtectFramework.PluginAPI:default] {"caused_by":[],"status_message":"Detected and remediated","execution_duration":3.4,"module":"XProtectRemediatorAdload","status_code":20,"type":"XPEvent.structured","subject":"/Users/papa/Library/Application Support/.x/agent"}
        2026-10-21 06:15:00.000 Df XProtectRemediatorAdload[20250:3e3aa3] [com.apple.launchservices:default] noise
        2026-10-22 21:42:01.958 F  XProtectRemediatorColdSnap[19585:8d588] [com.apple.XProtectFramework.PluginAPI:XPAPIHelpers] XPC connection interrupted.
        """
        let (runs, detections) = XProtectCheck.parseRemediatorLog(log)
        #expect(runs == 3)
        #expect(detections.count == 1)
        #expect(detections.first?.module == "Adload")
        #expect(detections.first?.subject == "/Users/papa/Library/Application Support/.x/agent")
    }

    @Test func adminOperationUpdatesDefinitions() throws {
        let command = try AdminRunner(log: nil).command(for: .updateXProtect)
        #expect(command == "/usr/bin/xprotect update" || command == "/usr/sbin/softwareupdate --background-critical")
    }
}
