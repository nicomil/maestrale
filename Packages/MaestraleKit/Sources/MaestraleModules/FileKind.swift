import Foundation
import UniformTypeIdentifiers

/// Broad kind of a file, used to group big files.
public enum FileKind: String, CaseIterable, Sendable {
    case video, audio, image, archive, diskImage, document, other

    public var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Immagini"
        case .archive: "Archivi"
        case .diskImage: "Immagini disco e installer"
        case .document: "Documenti"
        case .other: "Altri file"
        }
    }

    public static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ["dmg", "iso", "pkg", "mpkg", "sparseimage", "sparsebundle", "img"].contains(ext) { return .diskImage }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .archive) || ["zip", "rar", "7z", "tar", "gz", "xz", "bz2", "tgz"].contains(ext) {
            return .archive
        }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .text) || type.conforms(to: .compositeContent) {
            return .document
        }
        return .other
    }
}
