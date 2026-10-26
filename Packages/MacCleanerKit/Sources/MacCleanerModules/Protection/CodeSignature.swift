import Foundation
import Security

/// What the code signature of a file says about who made it.
public enum CodeSignature: Equatable, Sendable {
    case apple
    case signed(team: String?, notarized: Bool)
    case adHoc
    case unsigned
    case invalid

    public var team: String? {
        if case .signed(let team, _) = self { return team }
        return nil
    }
}

public protocol CodeSignatureEvaluator: Sendable {
    func signature(of url: URL) -> CodeSignature
}

/// The Security framework's verdict on a file or bundle.
public struct SecurityFrameworkSignatures: CodeSignatureEvaluator {
    public init() {}

    public func signature(of url: URL) -> CodeSignature {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return .unsigned }
        // Check the executable, not every resource: resource checks are slow and
        // fail for apps that legitimately add files to their bundle.
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil)
        if status == errSecCSUnsigned { return .unsigned }
        guard status == errSecSuccess else { return .invalid }

        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let dict = info as? [String: Any] ?? [:]
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        if let flags = dict[kSecCodeInfoFlags as String] as? UInt32, flags & 0x2 != 0 { return .adHoc } // kSecCodeSignatureAdhoc

        if Self.requirementSatisfied(code, "anchor apple") { return .apple }
        // Mac App Store apps are reviewed by Apple but carry no notarization
        // ticket: the leaf certificate marks them (OID 1.2.840.113635.100.6.1.9).
        let store = Self.requirementSatisfied(code, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]")
        return .signed(team: team, notarized: store || Self.requirementSatisfied(code, "notarized"))
    }

    static func requirementSatisfied(_ code: SecStaticCode, _ text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), requirement) == errSecSuccess
    }
}

/// Remembers each verdict for the length of a scan: the same program is
/// looked at by several checks (launch items, processes, TCC).
public final class CachedSignatures: CodeSignatureEvaluator, @unchecked Sendable {
    private let inner: any CodeSignatureEvaluator
    private var cache: [String: CodeSignature] = [:]
    private let lock = NSLock()

    public init(_ inner: any CodeSignatureEvaluator = SecurityFrameworkSignatures()) {
        self.inner = inner
    }

    public func signature(of url: URL) -> CodeSignature {
        let key = url.path
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let value = inner.signature(of: url)
        lock.lock(); cache[key] = value; lock.unlock()
        return value
    }
}

/// Fixed verdicts for tests, by path; anything else is `.apple`.
public struct FakeSignatures: CodeSignatureEvaluator {
    public var verdicts: [String: CodeSignature]
    public var fallback: CodeSignature

    public init(_ verdicts: [String: CodeSignature] = [:], fallback: CodeSignature = .apple) {
        self.verdicts = verdicts
        self.fallback = fallback
    }

    public func signature(of url: URL) -> CodeSignature {
        verdicts[url.path] ?? verdicts[url.standardizedFileURL.path] ?? fallback
    }
}

extension CodeSignature {
    /// Reasons and severity for a program that starts by itself or runs now.
    /// Package-manager programs are informational: Homebrew does not sign.
    public func assess(path: String) -> (reasons: [String], severity: Finding.Severity) {
        switch self {
        case .unsigned where KnownLocations.isFromPackageManager(path):
            return (["Programma non firmato installato da un gestore di pacchetti (es. Homebrew)"], .info)
        case .unsigned:
            return (["Il programma non è firmato"], .warning)
        case .adHoc:
            return (["Firma ad-hoc: nessuno sviluppatore identificato"], .warning)
        case .invalid:
            return (["La firma non è valida (file modificato?)"], .danger)
        case .signed(let team, let notarized):
            if !notarized && team != nil && !path.hasPrefix("/System") {
                return (["Firmato ma non notarizzato da Apple"], .warning)
            }
            return ([], .info)
        case .apple:
            return ([], .info)
        }
    }

    public var isAppleOrNotarized: Bool {
        switch self {
        case .apple: true
        case .signed(_, let notarized): notarized
        default: false
        }
    }
}
