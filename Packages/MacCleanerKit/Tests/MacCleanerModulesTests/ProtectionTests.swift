import Foundation
import MacCleanerCore
import Testing
@testable import MacCleanerModules

@Suite struct ProtectionTests {
    @Test func suspiciousLocations() {
        #expect(MalwareScanner.location("/tmp/x/agent") == .temporary)
        #expect(MalwareScanner.location("/Users/Shared/.hidden/run") == .temporary)
        #expect(MalwareScanner.location("/Users/me/Library/Application Support/.sys/update") == .hidden)
        #expect(MalwareScanner.location("/Applications/Zoom.app/Contents/MacOS/zoom") == .normal)
        #expect(MalwareScanner.location("/Library/Application Support/Vendor/helper") == .normal)
    }

    @Test func signatureClassification() throws {
        #expect(MalwareScanner.signature(of: URL(fileURLWithPath: "/bin/ls")) == .apple)
        let home = try FakeHome(); defer { home.remove() }
        let script = try home.file("tool.sh", bytes: 0)
        try "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(MalwareScanner.signature(of: script) == .unsigned)
    }

    @Test func installersOfInstalledAppsArePreselected() async throws {
        let home = try FakeHome(); defer { home.remove() }
        let app = home.url.appendingPathComponent("Applications/Zyxwapp.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "com.test.zyxwapp", "CFBundleName": "Zyxwapp"]
        info.write(to: app.appendingPathComponent("Info.plist"), atomically: true)
        for name in ["Downloads/Zyxwapp-2.1-arm64.dmg", "Downloads/Install Zyxwapp.pkg", "Downloads/random-tool.dmg"] {
            let file = try home.file(name, bytes: 1_500_000)
            let mark = "0081;6720a000;Safari;"
            #expect(setxattr(file.path, "com.apple.quarantine", mark, mark.utf8.count, 0, 0) == 0)
        }
        // Named like the app and not encrypted, but made by the user, not downloaded.
        try home.file("Documents/Zyxwapp-personal-backup.dmg", bytes: 1_500_000)
        // Named like the app, but the user's own data: never preselected.
        try home.file("Documents/Zyxwapp disk.sparseimage", bytes: 1_500_000)
        let encrypted = home.url.appendingPathComponent("Documents/Zyxwapp vault.dmg")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        create.arguments = ["create", "-size", "2m", "-fs", "HFS+", "-volname", "Vault", "-encryption", "AES-128",
                            "-stdinpass", "-quiet", encrypted.path]
        let password = Pipe()
        create.standardInput = password
        try create.run()
        password.fileHandleForWriting.write(Data("test".utf8))
        try password.fileHandleForWriting.close()
        create.waitUntilExit()
        #expect(create.terminationStatus == 0)

        let report = try await InstallersModule(home: home.url).scan()
        let installed = report.categories.first { $0.id == "installed" }?.items.map(\.displayName).sorted()
        #expect(installed == ["Install Zyxwapp.pkg", "Zyxwapp-2.1-arm64.dmg"])
        let other = try #require(report.categories.first { $0.id == "other-images" })
        #expect(Set(other.items.map(\.displayName)) == ["random-tool.dmg", "Zyxwapp disk.sparseimage",
                                                       "Zyxwapp vault.dmg", "Zyxwapp-personal-backup.dmg"])
        #expect(other.items.allSatisfy { !$0.autoSelect })
    }

    /// A manifest can claim any update_url: only the browser's own record
    /// says whether an extension came from the store.
    @Test func extensionOriginComesFromTheBrowserNotTheManifest() throws {
        let home = try FakeHome(); defer { home.remove() }
        let profile = home.url.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
        func install(_ id: String, updateURL: String) throws {
            let folder = profile.appendingPathComponent("Extensions/\(id)/1.0")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest: [String: Any] = ["name": id, "update_url": updateURL, "permissions": ["storage"]]
            try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        }
        try install("forged", updateURL: "https://google.com.attacker.invalid/update")
        try install("fromstore", updateURL: "https://clients2.google.com/service/update2/crx")
        let prefs: [String: Any] = ["extensions": ["settings": ["fromstore": ["creation_flags": 9, "location": 1]]]]
        try JSONSerialization.data(withJSONObject: prefs).write(to: profile.appendingPathComponent("Secure Preferences"))

        let findings = MalwareScanner(home: home.url).chromiumExtensions()
        #expect(findings.map(\.title) == ["Google Chrome: forged"])
        #expect(findings.first?.severity == .warning)
    }

    @Test func mailAttachmentsAreGroupedPerMessage() async throws {
        let home = try FakeHome(); defer { home.remove() }
        try home.file("Library/Mail/V10/ACCOUNT/INBOX.mbox/X/Data/1/Attachments/123/2/report.pdf", bytes: 50_000)
        try home.file("Library/Mail/V10/ACCOUNT/INBOX.mbox/X/Data/1/Attachments/456/1/photo.jpg", bytes: 70_000)
        let report = try await MailAttachmentsModule(home: home.url).scan()
        let items = try #require(report.categories.first { $0.id == "mail-attachments" }?.items)
        #expect(items.map(\.displayName).sorted() == ["123", "456"])
        #expect(items.first { $0.displayName == "123" }?.detail == "report.pdf")
    }
}

@Suite struct SystemStatsTests {
    @Test func snapshotIsSane() async throws {
        let monitor = SystemMonitor()
        _ = monitor.snapshot()
        try await Task.sleep(for: .milliseconds(200))
        let snap = monitor.snapshot()
        #expect(snap.memoryTotal > 0)
        #expect(snap.memoryUsed > 0 && snap.memoryUsed <= snap.memoryTotal)
        #expect(snap.diskTotal > 0 && snap.diskFree > 0 && snap.diskFree < snap.diskTotal)
        #expect((0...1).contains(snap.cpuUsage))
    }
}
