import Foundation
import MaestraleCore

/// The user's Trash and the Trash folders of mounted volumes.
/// Emptying them is permanent, so nothing is selected by default.
public struct TrashModule: CleanerModule {
    public static let id = "trash"
    public var id: String { Self.id }
    public let title = "Cestini"
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func scan() async throws -> ScanReport {
        // Empty files and folders must go too: the Trash is emptied, not tidied.
        let engine = RuleEngine(home: home, includeEmptyItems: true)
        let output = engine.evaluate(Self.rules)
        return ScanReport(moduleID: id, categories: output.categories, unreadablePaths: output.unreadable)
    }

    /// Folders whose content can be removed by this module.
    public var allowedRoots: [URL] {
        [home.appendingPathComponent(".Trash")] + RuleEngine(home: home).expand("/Volumes/*/.Trashes/$UID")
    }

    static let rules: RuleSet = {
        let json = """
        {
          "version": 1,
          "rules": [
            {"id": "user-trash", "category": "user-trash", "title": "Cestino",
             "paths": ["~/.Trash"], "risk": "high", "autoSelect": false},
            {"id": "volume-trashes", "category": "volume-trashes", "title": "Cestini dei dischi esterni",
             "paths": ["/Volumes/*/.Trashes/$UID"], "risk": "high", "autoSelect": false}
          ]
        }
        """
        // The JSON above is fixed and tested, so a failure here is a programming error.
        return try! JSONDecoder().decode(RuleSet.self, from: Data(json.utf8))
    }()
}
