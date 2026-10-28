import Foundation
import MaestraleCore

/// Installed apps with a missing or broken signature, and apps that reached
/// /Applications without ever going through Gatekeeper.
public struct AppsSignatureCheck: ProtectionCheck {
    public let id = "apps-signature"
    public let title = "Firme delle app"
    let folders: [URL]?

    public init(folders: [URL]? = nil) { self.folders = folders }

    public func run(_ context: CheckContext) -> [Finding] {
        var findings: [Finding] = []
        for app in AppInventory(home: context.home, folders: folders).appURLs() {
            let signature = context.signatures.signature(of: app)
            switch signature {
            case .unsigned:
                findings.append(Finding(category: .application, key: app.path, severity: .warning, title: app.lastPathComponent,
                                        path: app, reasons: ["App non firmata"], action: .trash))
            case .invalid:
                findings.append(Finding(category: .application, key: app.path, severity: .warning, title: app.lastPathComponent,
                                        path: app, reasons: ["Firma dell'eseguibile non valida: l'app è stata modificata dopo la firma"],
                                        action: .trash))
            case .adHoc:
                // Downloaded apps carry the quarantine attribute until Gatekeeper
                // approves them. An ad-hoc signed app without it was either built
                // on this Mac or had the attribute stripped (xattr -c). The
                // notarization check alone is too unreliable offline to flag
                // Developer ID apps the same way.
                guard app.path.hasPrefix("/Applications/"), !Self.hasQuarantineAttribute(app) else { continue }
                findings.append(Finding(category: .application, key: app.path, severity: .info, title: app.lastPathComponent,
                                        path: app,
                                        reasons: ["Firma ad-hoc e nessun attributo di quarantena: non è passata da Gatekeeper"],
                                        evidence: ["Nessun attributo com.apple.quarantine su \(app.path)"],
                                        action: .trash))
            default:
                break
            }
        }
        return findings
    }

    static func hasQuarantineAttribute(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}
