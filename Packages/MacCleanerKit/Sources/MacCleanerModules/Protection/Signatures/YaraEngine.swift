import CYara
import Foundation

/// One rule that matched a file.
public struct YaraMatch: Sendable, Hashable {
    public let rule: String
    public let namespace: String
    public let tags: [String]
    public let meta: [String: String]

    /// "danger", "warning" or "info" from the rule's `severity` meta; danger otherwise.
    public var severity: Finding.Severity {
        switch (meta["severity"] ?? meta["level"] ?? "").lowercased() {
        case "info", "low": .info
        case "warning", "medium", "suspicious": .warning
        default: .danger
        }
    }

    public var description: String { meta["description"] ?? meta["desc"] ?? rule }
    public var source: String { meta["author"].map { "\(namespace) · \($0)" } ?? namespace }
}

public enum YaraError: Error, Equatable, CustomStringConvertible {
    case initialization(Int32)
    case compilation([String])
    case scan(Int32)

    public var description: String {
        switch self {
        case .initialization(let code): "libyara non inizializzata (\(code))"
        case .compilation(let errors): "regole non valide: " + errors.prefix(3).joined(separator: "; ")
        case .scan(let code): "scansione fallita (\(code))"
        }
    }
}

/// libyara, compiled rules in hand. Create one per rule set and reuse it for
/// every file: compiling is the slow part.
public final class YaraEngine: @unchecked Sendable {
    private var rules: UnsafeMutablePointer<YR_RULES>?
    private let lock = NSLock()
    public let warnings: [String]
    public let ruleCount: Int

    private static let initialized: Int32 = yr_initialize()

    /// Compiles the given rule sources, each under its own namespace.
    public init(sources: [(namespace: String, text: String)]) throws {
        guard Self.initialized == ERROR_SUCCESS else { throw YaraError.initialization(Self.initialized) }
        var compiler: UnsafeMutablePointer<YR_COMPILER>?
        guard yr_compiler_create(&compiler) == ERROR_SUCCESS, let compiler else { throw YaraError.initialization(-1) }
        defer { yr_compiler_destroy(compiler) }
        let messages = Messages()
        yr_compiler_set_callback(compiler, { level, file, line, rule, message, data in
            guard let data, let message else { return }
            let box = Unmanaged<Messages>.fromOpaque(data).takeUnretainedValue()
            let text = "\(line): \(String(cString: message))" + (rule.map { " (\(String(cString: $0.pointee.identifier)))" } ?? "")
            if level == YARA_ERROR_LEVEL_ERROR { box.errors.append(text) } else { box.warnings.append(text) }
        }, Unmanaged.passUnretained(messages).toOpaque())
        var errors = 0
        for source in sources {
            errors += Int(yr_compiler_add_string(compiler, source.text, source.namespace))
        }
        guard errors == 0 else { throw YaraError.compilation(messages.errors) }
        var compiled: UnsafeMutablePointer<YR_RULES>?
        guard yr_compiler_get_rules(compiler, &compiled) == ERROR_SUCCESS, let compiled else { throw YaraError.initialization(-2) }
        rules = compiled
        warnings = messages.warnings
        var count = 0
        var rule = compiled.pointee.rules_table
        while let current = rule, current.pointee.flags & Int32(RULE_FLAGS_NULL) == 0 {
            count += 1
            rule = current.advanced(by: 1)
        }
        ruleCount = count
    }

    deinit {
        if let rules { yr_rules_destroy(rules) }
    }

    private final class Messages {
        var errors: [String] = []
        var warnings: [String] = []
    }

    private final class Matches {
        var matches: [YaraMatch] = []
    }

    /// Scans one file; `timeout` in seconds.
    public func scan(file: URL, timeout: Int32 = 10) throws -> [YaraMatch] {
        guard let rules else { return [] }
        lock.lock(); defer { lock.unlock() }
        let matches = Matches()
        let result = yr_rules_scan_file(rules, file.path, Int32(SCAN_FLAGS_FAST_MODE), { _, message, data, user in
            guard let user else { return CALLBACK_CONTINUE }
            let box = Unmanaged<Matches>.fromOpaque(user).takeUnretainedValue()
            if message == CALLBACK_MSG_RULE_MATCHING, let data {
                box.matches.append(YaraEngine.match(from: data.assumingMemoryBound(to: YR_RULE.self)))
            }
            return CALLBACK_CONTINUE
        }, Unmanaged.passUnretained(matches).toOpaque(), timeout)
        guard result == ERROR_SUCCESS else { throw YaraError.scan(result) }
        return matches.matches
    }

    static func match(from rule: UnsafeMutablePointer<YR_RULE>) -> YaraMatch {
        let identifier = String(cString: rule.pointee.identifier)
        let namespace = rule.pointee.ns.map { String(cString: $0.pointee.name) } ?? ""
        var tags: [String] = []
        if var tag = rule.pointee.tags {
            while tag.pointee != 0 {
                let text = String(cString: tag)
                tags.append(text)
                tag = tag.advanced(by: text.utf8.count + 1)
            }
        }
        var meta: [String: String] = [:]
        // Metas are a contiguous array; the last one carries META_FLAGS_LAST_IN_RULE.
        if var entry = rule.pointee.metas {
            while true {
                let key = String(cString: entry.pointee.identifier)
                switch entry.pointee.type {
                case Int32(META_TYPE_STRING): meta[key] = String(cString: entry.pointee.string)
                case Int32(META_TYPE_INTEGER): meta[key] = String(entry.pointee.integer)
                case Int32(META_TYPE_BOOLEAN): meta[key] = entry.pointee.integer != 0 ? "true" : "false"
                default: break
                }
                if entry.pointee.flags & Int32(META_FLAGS_LAST_IN_RULE) != 0 { break }
                entry = entry.advanced(by: 1)
            }
        }
        return YaraMatch(rule: identifier, namespace: namespace, tags: tags, meta: meta)
    }
}
