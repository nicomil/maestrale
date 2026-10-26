import Foundation
import Testing
@testable import MacCleanerCore

@Suite struct RuleEngineTests {
    func rules(_ json: String) throws -> RuleSet {
        try JSONDecoder().decode(RuleSet.self, from: Data(json.utf8))
    }

    @Test func expandsTildeAndWildcards() throws {
        let box = try Sandbox(); defer { box.remove() }
        try box.file("Library/Containers/com.a/Data/Library/Caches/x", in: box.allowed)
        try box.file("Library/Containers/com.b/Data/Library/Caches/y", in: box.allowed)
        try box.file("Library/Containers/com.c/Data/other", in: box.allowed)
        let engine = RuleEngine(home: box.allowed)
        let found = engine.expand("~/Library/Containers/*/Data/Library/Caches").map(\.path).sorted()
        #expect(found.count == 2)
        #expect(found[0].hasSuffix("com.a/Data/Library/Caches"))
    }

    @Test func childrenTargetAppliesExcludesAndProtectedNames() throws {
        let box = try Sandbox(); defer { box.remove() }
        try box.file("Library/Caches/com.keep.me/a", in: box.allowed)
        try box.file("Library/Caches/com.apple.bird/a", in: box.allowed)
        try box.file("Library/Caches/com.running.app/a", in: box.allowed)
        try box.file("Library/Caches/.DS_Store", in: box.allowed)
        let set = try rules("""
        {"version": 1, "globalExcludes": ["com.apple.bird"],
         "rules": [{"id": "c", "category": "caches", "title": "Cache", "paths": ["~/Library/Caches"]}]}
        """)
        let out = RuleEngine(home: box.allowed, protectedNames: ["com.running.app"]).evaluate(set)
        let names = out.categories.flatMap(\.items).map(\.displayName)
        #expect(names == ["com.keep.me"])
    }

    /// The container of a running app holds its caches under a folder that is
    /// not named after the app: the whole container must count as the app's.
    @Test func cachesInsideARunningAppContainerAreSkipped() throws {
        let box = try Sandbox(); defer { box.remove() }
        try box.file("Library/Containers/com.running.app/Data/Library/Caches/blob", in: box.allowed)
        try box.file("Library/Containers/com.closed.app/Data/Library/Caches/blob", in: box.allowed)
        try box.file("Library/Caches/com.running.app.ShipIt/update", in: box.allowed)
        try box.file("Library/Caches/ABCD1234.com.running.app/x", in: box.allowed)
        let set = try rules("""
        {"version": 1, "rules": [
          {"id": "c", "category": "caches", "title": "Cache", "paths": ["~/Library/Caches"]},
          {"id": "k", "category": "caches", "title": "Cache", "paths": ["~/Library/Containers/*/Data/Library/Caches"]}]}
        """)
        let out = RuleEngine(home: box.allowed, protectedNames: ["com.running.app"]).evaluate(set)
        let paths = out.categories.flatMap(\.items).map(\.url.path)
        #expect(paths.count == 1)
        #expect(paths.allSatisfy { $0.contains("com.closed.app") })
        #expect(!RuleEngine.isProtected(URL(fileURLWithPath: "/Users/x/Library/Caches/com.running.application"),
                                        by: ["com.running.app"]))
    }

    @Test func itselfTargetAndDefaults() throws {
        let box = try Sandbox(); defer { box.remove() }
        try box.file(".gradle/caches/big.bin", in: box.allowed, bytes: 50_000)
        let set = try rules("""
        {"version": 1, "rules": [{"id": "g", "category": "dev", "title": "Dev",
          "paths": ["~/.gradle/caches"], "target": "itself", "risk": "medium", "autoSelect": false}]}
        """)
        let item = try #require(RuleEngine(home: box.allowed).evaluate(set).categories.first?.items.first)
        #expect(item.displayName == "caches")
        #expect(item.risk == .medium)
        #expect(item.autoSelect == false)
        #expect(item.needsHelper == false)
        #expect(item.size >= 50_000)
    }

    @Test func minAgeSkipsRecentItems() throws {
        let box = try Sandbox(); defer { box.remove() }
        let old = try box.file("Logs/old.log", in: box.allowed)
        try box.file("Logs/new.log", in: box.allowed)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 86_400)],
                                              ofItemAtPath: old.path)
        let set = try rules("""
        {"version": 1, "rules": [{"id": "l", "category": "logs", "title": "Log",
          "paths": ["~/Logs"], "minAgeDays": 7}]}
        """)
        let names = RuleEngine(home: box.allowed).evaluate(set).categories.flatMap(\.items).map(\.displayName)
        #expect(names == ["old.log"])
    }

    @Test func overlappingRulesKeepOnlyTheOutermostItem() throws {
        let box = try Sandbox(); defer { box.remove() }
        try box.file("Library/Caches/Google/Chrome/Default/Cache/data", in: box.allowed)
        let set = try rules("""
        {"version": 1, "rules": [
          {"id": "all", "category": "caches", "title": "Cache", "paths": ["~/Library/Caches"]},
          {"id": "chrome", "category": "browser", "title": "Browser",
           "paths": ["~/Library/Caches/Google/Chrome/*/Cache"], "target": "itself"},
          {"id": "again", "category": "again", "title": "Again", "paths": ["~/Library/Caches"]}
        ]}
        """)
        let out = RuleEngine(home: box.allowed).evaluate(set)
        #expect(out.categories.map(\.id) == ["caches"])
        #expect(out.categories.first?.items.map(\.displayName) == ["Google"])
    }

    @Test func emptyFoldersAreNotReported() throws {
        let box = try Sandbox(); defer { box.remove() }
        try FileManager.default.createDirectory(at: box.allowed.appendingPathComponent("Library/Caches/empty"),
                                                withIntermediateDirectories: true)
        let set = try rules("""
        {"version": 1, "rules": [{"id": "c", "category": "caches", "title": "Cache", "paths": ["~/Library/Caches"]}]}
        """)
        #expect(RuleEngine(home: box.allowed).evaluate(set).categories.isEmpty)
    }
}
