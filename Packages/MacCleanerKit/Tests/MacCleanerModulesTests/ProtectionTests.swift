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
        try home.file("Downloads/Zyxwapp-2.1-arm64.dmg", bytes: 1_500_000)
        try home.file("Downloads/Install Zyxwapp.pkg", bytes: 1_500_000)
        try home.file("Downloads/random-tool.dmg", bytes: 1_500_000)

        let report = try await InstallersModule(home: home.url).scan()
        let installed = report.categories.first { $0.id == "installed" }?.items.map(\.displayName).sorted()
        #expect(installed == ["Install Zyxwapp.pkg", "Zyxwapp-2.1-arm64.dmg"])
        let other = try #require(report.categories.first { $0.id == "other-images" })
        #expect(other.items.map(\.displayName) == ["random-tool.dmg"])
        #expect(other.items.allSatisfy { !$0.autoSelect })
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
