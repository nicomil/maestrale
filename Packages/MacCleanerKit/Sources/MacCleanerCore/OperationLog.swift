import Foundation

/// Appends one line per removal to a log file, so every change can be traced.
public final class OperationLog: Sendable {
    public let fileURL: URL
    private let queue = DispatchQueue(label: "maccleaner.operation-log")

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Logs/MacCleaner/operations.log`
    public static let standard = OperationLog(
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacCleaner/operations.log")
    )

    func record(mode: RemovalMode, outcome: RemovalOutcome) {
        let status: String
        switch outcome.result {
        case .success(let bytes): status = "ok \(bytes)"
        case .failure(let error): status = "refused \(error)"
        }
        append("\(ISO8601DateFormatter().string(from: Date()))\t\(mode.rawValue)\t\(status)\t\(outcome.url.path)\n")
    }

    private func append(_ line: String) {
        let url = fileURL
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Records an operation run with administrator rights.
    public func recordAdmin(_ title: String, ok: Bool, detail: String) {
        append("\(ISO8601DateFormatter().string(from: Date()))\tadmin\t\(ok ? "ok" : "failed")\t\(title)\t\(detail)\n")
    }

    /// Waits until every pending line has been written. Used by tests.
    public func flush() {
        queue.sync {}
    }
}
