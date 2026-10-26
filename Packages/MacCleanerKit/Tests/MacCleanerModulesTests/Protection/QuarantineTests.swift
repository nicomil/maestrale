import Foundation
import MacCleanerCore
import Testing
@testable import MacCleanerModules

@Suite struct QuarantineTests {
    @Test func quarantineRestoreAndDeleteRoundTrip() throws {
        let home = try TempHome(); defer { home.remove() }
        let quarantine = Quarantine(folder: home.url.appendingPathComponent("Quarantine"), log: nil)
        let agent = try home.executable("Library/Application Support/Evil/agent")
        try home.write("Library/Application Support/Evil/data/config.json", "{}")
        let roots = [home.url.appendingPathComponent("Library/Application Support")]

        let record = try quarantine.quarantine(agent.deletingLastPathComponent(), title: "Evil", reasons: ["test"], allowedRoots: roots)
        #expect(!FileManager.default.fileExists(atPath: agent.path))
        #expect(record.storedName == "Evil")
        #expect(record.originalPath.hasSuffix("/Library/Application Support/Evil"))
        #expect(quarantine.records().map(\.id) == [record.id])
        let stored = URL(fileURLWithPath: record.storedPath)
        #expect(FileManager.default.fileExists(atPath: stored.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions] as? Int
        #expect(permissions == 0)
        // Nothing inside can be read either, so the mark is checked after unlocking.
        #expect(!FileManager.default.isReadableFile(atPath: stored.appendingPathComponent("agent").path))
        Quarantine.unlock(stored)
        #expect(getxattr(stored.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0)
        Quarantine.lock(stored)

        // Something else took the place: restore refuses.
        try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(throws: PinnedFileError.self) { try quarantine.restore(record) }
        try FileManager.default.removeItem(at: agent.deletingLastPathComponent())

        try quarantine.restore(record)
        #expect(FileManager.default.fileExists(atPath: agent.path))
        #expect(FileManager.default.isExecutableFile(atPath: agent.path))
        #expect(quarantine.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: record.storedFolder))

        let again = try quarantine.quarantine(agent, title: "agent", reasons: [], allowedRoots: roots)
        try quarantine.delete(again)
        #expect(!FileManager.default.fileExists(atPath: again.storedFolder))
        #expect(quarantine.records().isEmpty)
    }

    @Test func refusesPathsOutsideTheRootsAndSymlinkedParents() throws {
        let home = try TempHome(); defer { home.remove() }
        let quarantine = Quarantine(folder: home.url.appendingPathComponent("Quarantine"), log: nil)
        let outside = try home.write("Documents/precious.txt", "keep")
        let roots = [home.url.appendingPathComponent("Library/Application Support")]
        #expect(throws: PinnedFileError.self) {
            try quarantine.quarantine(outside, title: "x", reasons: [], allowedRoots: roots)
        }
        // A symlink inside the root pointing outside: the link itself moves, not the target.
        let link = home.url.appendingPathComponent("Library/Application Support/link")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let record = try quarantine.quarantine(link, title: "link", reasons: [], allowedRoots: roots)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
        lchmod(record.storedPath, 0o700)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: record.storedPath)) == outside.path)
    }

    @Test func adminQuarantineCommandsAreBuiltAndValidated() throws {
        let helper = FileManager.default.temporaryDirectory.appendingPathComponent("fake-helper-\(UUID().uuidString)")
        try "#!/bin/sh\necho ok\n".write(to: helper, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: helper) }
        let runner = AdminRunner(log: nil, helper: helper)
        let id = UUID()
        guard let cache = ((try? FileManager.default.contentsOfDirectory(atPath: "/Library/Caches")) ?? [])
            .first(where: { PinnedFileSystem.isPlainName($0) && FileManager.default.fileExists(atPath: "/Library/Caches/\($0)")
                && !SafeRemover.isSystemProtected(URL(fileURLWithPath: "/Library/Caches/\($0)")) }) else { return }
        let command = try runner.command(for: .quarantine([URL(fileURLWithPath: "/Library/Caches/\(cache)")], id: id))
        #expect(command.contains("/bin/mkdir -p -m 700 '/Library/Application Support/MacCleaner/Quarantine/\(id.uuidString)'"))
        #expect(command.contains("'trash' '/Library/Application Support/MacCleaner/Quarantine/\(id.uuidString)' '0' '/Library/Caches' '\(cache)'"))
        #expect(command.contains("/bin/chmod -R 000"))
        #expect(throws: AdminError.self) { try runner.command(for: .quarantine([URL(fileURLWithPath: "/etc/hosts")], id: id)) }

        let restore = try runner.command(for: .restoreQuarantined(id: id, name: "agent", into: URL(fileURLWithPath: "/Library/LaunchDaemons")))
        #expect(restore.contains("'trash' '/Library/LaunchDaemons' '0' '/Library/Application Support/MacCleaner/Quarantine/\(id.uuidString)' 'agent'"))
        #expect(throws: AdminError.self) { try runner.command(for: .restoreQuarantined(id: id, name: "../x", into: URL(fileURLWithPath: "/Library/LaunchDaemons"))) }
        #expect(throws: AdminError.self) { try runner.command(for: .restoreQuarantined(id: id, name: "x", into: URL(fileURLWithPath: "/etc"))) }

        let delete = try runner.command(for: .deleteQuarantined(id: id))
        #expect(delete.contains("'remove' '/Library/Application Support/MacCleaner/Quarantine' '\(id.uuidString)'"))
    }
}

@Suite struct ProtectionReportTests {
    @Test func reportListsStatusAndFindingsByCategory() {
        let status = ProtectionStatus(gatekeeperEnabled: true, sipEnabled: false, xprotectVersion: "5368", firewallEnabled: nil)
        var danger = Finding(category: .persistence, key: "a", severity: .danger, title: "com.evil.agent",
                             path: URL(fileURLWithPath: "/tmp/evil"), reasons: ["Avviato da /tmp"], evidence: ["Label: com.evil.agent"])
        danger.isNew = true
        let info = Finding(category: .defense, key: "b", severity: .info, title: "Ospite attivo", reasons: ["x"])
        let ignored = Finding(category: .browser, key: "c", severity: .warning, title: "Ext", reasons: ["y"])
        let text = ProtectionReport.markdown(status: status, findings: [danger, info, ignored], ignored: [ignored.id],
                                             date: Date(timeIntervalSince1970: 0), host: "iMac di papà")
        #expect(text.hasPrefix("# Rapporto Protezione · iMac di papà"))
        #expect(text.contains("- Protezione integrità (SIP): **DISATTIVATO**"))
        #expect(text.contains("- Firewall: sconosciuto"))
        #expect(text.contains("- Pericoli: 1"))
        #expect(text.contains("- Nuovi dall'ultimo controllo: 1"))
        #expect(text.contains("- Ignorati dall'utente: 1"))
        #expect(text.contains("### PERICOLO · nuovo: com.evil.agent"))
        #expect(text.contains("- Percorso: `/tmp/evil`"))
        #expect(text.contains("Label: com.evil.agent"))
        #expect(!text.contains("### Avviso: Ext"))
        #expect(text.contains("## Difese di macOS"))
    }
}
