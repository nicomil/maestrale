import Foundation
import MaestraleCore
import Testing
@testable import MaestraleModules

@Suite struct SystemJunkRulesTests {
    let home = URL(fileURLWithPath: "/Users/tester")

    @Test func bundledRulesDecode() throws {
        let set = try SystemJunkModule.bundledRules()
        #expect(set.rules.count > 10)
        #expect(Set(set.rules.map(\.id)).count == set.rules.count, "rule ids must be unique")
    }

    /// Every rule that runs without the helper must stay strictly inside an
    /// allowed folder, otherwise SafeRemover would refuse its items.
    @Test func userRulesStayInsideAllowedRoots() throws {
        let roots = AllowedRoots.user(home: home).map(\.path)
        for rule in try SystemJunkModule.bundledRules().rules where !rule.needsHelper {
            for pattern in rule.paths {
                let path = pattern.replacingOccurrences(of: "~", with: home.path)
                // For "children" rules the items are one level below the path.
                let itemPath = rule.target == .children ? path + "/item" : path
                let inside = roots.contains { itemPath.hasPrefix($0 + "/") }
                #expect(inside, "\(rule.id): \(pattern) is not inside an allowed root")
            }
        }
    }

    @Test func riskyCategoriesAreNeverPreselected() throws {
        for rule in try SystemJunkModule.bundledRules().rules where rule.risk == .high {
            #expect(!rule.autoSelect, "\(rule.id) is high risk and must not be preselected")
        }
    }

    @Test func trashRulesDecode() {
        #expect(TrashModule.rules.rules.count == 2)
    }
}
