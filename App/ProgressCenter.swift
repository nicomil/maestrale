import Foundation
import MacCleanerCore
import SwiftUI

/// One place that knows about the long operation in progress, whatever screen
/// started it. `ProgressBanner` shows it at the bottom of every screen.
///
/// An operation has a title, an optional count and byte total, a detail line
/// (what is being handled right now) and may be interruptible: stopping lets
/// the current item finish and leaves the rest untouched.
@MainActor
@Observable
final class ProgressCenter {
    static let shared = ProgressCenter()

    struct Operation: Equatable {
        var title: String
        var detail: String?
        var completed = 0
        var total = 0
        var bytesDone: Int64 = 0
        var bytesTotal: Int64 = 0
        var started = Date()
        var canStop = false
        var stopRequested = false

        /// Fraction done, nil when the operation has no measurable size.
        var fraction: Double? {
            if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
            if total > 0 { return min(1, Double(completed) / Double(total)) }
            return nil
        }

        /// "3 di 12 elementi · 2,1 GB di 10,3 GB"
        var counts: String? {
            var parts: [String] = []
            if total > 0 { parts.append("\(completed) di \(total) elementi") }
            if bytesTotal > 0 {
                parts.append("\(ByteCountFormatter.string(fromByteCount: bytesDone, countStyle: .file)) di "
                             + ByteCountFormatter.string(fromByteCount: bytesTotal, countStyle: .file))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    private(set) var current: Operation?
    /// Reports arrive from background threads: at most one every tenth of a
    /// second reaches the screen, plus the last one.
    private let sink = ThrottledSink()

    /// Starts an operation. A previous one still shown is replaced.
    func begin(_ title: String, total: Int = 0, bytesTotal: Int64 = 0, canStop: Bool = false, detail: String? = nil) {
        sink.reset()
        current = Operation(title: title, detail: detail, total: total, bytesTotal: bytesTotal, canStop: canStop)
    }

    /// A step with no measurable progress, for example waiting for the password.
    func phase(_ detail: String) {
        current?.detail = detail
    }

    func update(completed: Int? = nil, bytesDone: Int64? = nil, detail: String? = nil) {
        guard current != nil else { return }
        if let completed { current?.completed = completed }
        if let bytesDone { current?.bytesDone = bytesDone }
        if let detail { current?.detail = detail }
    }

    func end() {
        current = nil
    }

    /// Asks the running operation to stop after the current item.
    func stop() {
        guard current?.canStop == true else { return }
        current?.stopRequested = true
        current?.detail = "Mi fermo dopo l'elemento in corso…"
        sink.stopRequested = true
    }

    var stopRequested: Bool { current?.stopRequested == true }

    /// A `SafeRemover.remove` progress callback that feeds this center.
    /// `verb` is what is happening to each item: "Elimino", "Sposto nel Cestino".
    nonisolated func removalReporter(verb: String, sizes: [URL: Int64] = [:]) -> @Sendable (RemovalProgress) -> Void {
        let sink = sink
        return { progress in
            let last = progress.completed == progress.total
            guard sink.shouldSend(force: last) else { return }
            let detail: String? = progress.next.map { url in
                let size = sizes[url].map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? ""
                return "\(verb) «\(url.lastPathComponent)»\(size)"
            }
            Task { @MainActor in
                ProgressCenter.shared.update(completed: progress.completed, bytesDone: progress.bytesDone,
                                             detail: detail ?? (last ? "Quasi fatto…" : nil))
            }
        }
    }

    /// A `shouldContinue` closure for `SafeRemover.remove`.
    nonisolated func continuation() -> @Sendable () -> Bool {
        let flag = sink
        return { !flag.stopRequested }
    }
}

/// Throttles progress reports coming from a background thread.
final class ThrottledSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSent = Date.distantPast
    private var _stop = false
    private let interval: TimeInterval = 0.1

    var stopRequested: Bool {
        get { lock.withLock { _stop } }
        set { lock.withLock { _stop = newValue } }
    }

    func reset() {
        lock.withLock { lastSent = .distantPast; _stop = false }
    }

    func shouldSend(force: Bool) -> Bool {
        lock.withLock {
            let now = Date()
            guard force || now.timeIntervalSince(lastSent) >= interval else { return false }
            lastSent = now
            return true
        }
    }
}

/// The banner at the bottom of every screen while an operation runs.
struct ProgressBanner: View {
    private var center: ProgressCenter { ProgressCenter.shared }

    var body: some View {
        if let op = center.current {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(op.title).font(.headline)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.elapsed(since: op.started, now: context.date))
                            .monospacedDigit().foregroundStyle(.secondary).font(.callout)
                    }
                }
                if let fraction = op.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let counts = op.counts {
                            Text(counts).font(.callout).monospacedDigit()
                        }
                        Text(op.detail ?? "In corso…")
                            .font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if op.canStop {
                        Button("Interrompi") { center.stop() }
                            .disabled(op.stopRequested)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds) s" : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
