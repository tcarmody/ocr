import Foundation
import SwiftUI
import PDFIngest

/// Async two-up processor. Drives the drop pipeline through three
/// phases — detect → user decision → split — without blocking the
/// main thread. The view layer observes `phase` and renders the
/// progress sheet / decision buttons; this object owns no UI.
///
/// Cancellation is cooperative: `cancel()` flips the `cancelled`
/// flag, the running Task observes it between files, and any
/// outstanding decision continuation is resumed with `.cancel`.
@MainActor
final class TwoUpProcessor: ObservableObject {

    /// What the user picks at the decision step. `.decideEach` is
    /// only offered in the bulk case; the single-file flow only
    /// surfaces split / asIs / cancel.
    enum Decision {
        case split
        case asIs
        case decideEach
        case cancel
    }

    /// Each phase carries the data the sheet needs to render itself.
    /// Counts/indexes are 1-based for display ("Detecting 3 of 5").
    enum Phase: Equatable {
        case idle
        case detecting(name: String, index: Int, total: Int)
        case awaitingDecision(twoUpURLs: [URL], totalCount: Int, isBulk: Bool)
        case awaitingSingleDecision(url: URL)
        case splitting(name: String, index: Int, total: Int)
    }

    @Published private(set) var phase: Phase = .idle

    /// Set by `cancel()`; checked between files. Reset on each new
    /// `process(_:)` invocation so a previous cancel doesn't bleed.
    private var cancelled = false

    /// The decision step suspends on this continuation; the sheet
    /// resumes it via `provideDecision(_:)`. Only one outstanding
    /// at a time — multiple drops would already be serialized by
    /// the Task in `ContentView`.
    private var decisionContinuation: CheckedContinuation<Decision, Never>?

    /// Drive the full pipeline for a batch of dropped PDFs. Returns
    /// the URLs that should be enqueued (originals or split copies),
    /// preserving input order. Empty array if cancelled.
    ///
    /// Folders are not handled here — the caller should enumerate
    /// folder contents and pass plain PDF URLs in. Per the prior
    /// design call we don't prompt per-file inside a folder drop;
    /// folders enqueue as-is.
    func process(_ pdfs: [URL]) async -> [URL] {
        cancelled = false
        defer { phase = .idle }

        // Phase 1: detection. Build a map url → isTwoUp so we can
        // both report counts in the prompt and remember which files
        // need splitting after the user decides.
        var detection: [(url: URL, isTwoUp: Bool)] = []
        for (i, url) in pdfs.enumerated() {
            if cancelled { return [] }
            phase = .detecting(name: url.lastPathComponent, index: i + 1, total: pdfs.count)
            let isTwoUp = await Self.detect(url)
            detection.append((url, isTwoUp))
        }
        if cancelled { return [] }

        let twoUpURLs = detection.filter(\.isTwoUp).map(\.url)

        // Fast path: nothing looks two-up — enqueue everything as-is.
        if twoUpURLs.isEmpty {
            return pdfs
        }

        // Phase 2: ask the user. Single vs bulk uses different prompts.
        let decision: Decision
        if twoUpURLs.count == 1 {
            phase = .awaitingSingleDecision(url: twoUpURLs[0])
            decision = await awaitDecision()
        } else {
            phase = .awaitingDecision(
                twoUpURLs: twoUpURLs,
                totalCount: pdfs.count,
                isBulk: true
            )
            decision = await awaitDecision()
        }

        switch decision {
        case .cancel:
            return []
        case .asIs:
            return pdfs
        case .split:
            return await runSplit(detection: detection, perFilePrompt: false)
        case .decideEach:
            return await runSplit(detection: detection, perFilePrompt: true)
        }
    }

    /// Called by the sheet's buttons. Safe to call when no one is
    /// waiting — it just no-ops (the phase will already have moved
    /// on, e.g. via `cancel()`).
    func provideDecision(_ d: Decision) {
        guard let cont = decisionContinuation else { return }
        decisionContinuation = nil
        cont.resume(returning: d)
    }

    /// Cooperative cancel. Resumes any pending decision with
    /// `.cancel` so the awaiting Task unwinds cleanly.
    func cancel() {
        cancelled = true
        if let cont = decisionContinuation {
            decisionContinuation = nil
            cont.resume(returning: .cancel)
        }
    }

    // MARK: - private

    private func awaitDecision() async -> Decision {
        await withCheckedContinuation { cont in
            self.decisionContinuation = cont
        }
    }

    /// Run splits for the two-up entries in `detection`, optionally
    /// prompting once per file (`.decideEach` path). Returns the
    /// resolved URL list in the original input order — files the
    /// user chose to skip drop out entirely.
    private func runSplit(
        detection: [(url: URL, isTwoUp: Bool)],
        perFilePrompt: Bool
    ) async -> [URL] {
        let twoUpCount = detection.filter(\.isTwoUp).count
        var splitIndex = 0
        var resolved: [URL] = []

        for entry in detection {
            if cancelled { return [] }
            guard entry.isTwoUp else {
                resolved.append(entry.url)
                continue
            }
            // Per-file prompt for `.decideEach`. We reuse the
            // single-decision phase so the sheet renders the same
            // single-file UI — just looped.
            if perFilePrompt {
                phase = .awaitingSingleDecision(url: entry.url)
                let d = await awaitDecision()
                switch d {
                case .cancel: return []
                case .asIs:
                    resolved.append(entry.url)
                    continue
                case .split, .decideEach:
                    break  // fall through to split
                }
            }
            splitIndex += 1
            phase = .splitting(
                name: entry.url.lastPathComponent,
                index: splitIndex,
                total: twoUpCount
            )
            if let split = await Self.split(entry.url) {
                resolved.append(split)
            } else {
                // Splitter logged via NSAlert; fall back to original
                // so the user still gets a job rather than silent loss.
                resolved.append(entry.url)
            }
        }
        return resolved
    }

    // Off-main wrappers around the synchronous PDFKit work. We
    // hop to `.userInitiated` so detection/splitting don't block
    // the main thread; both functions are pure value-in/value-out.

    private static func detect(_ url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            TwoUpDetector.detectIsTwoUp(pdfURL: url)
        }.value
    }

    private static func split(_ url: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            let outputURL = url
                .deletingPathExtension()
                .appendingPathExtension("split")
                .appendingPathExtension("pdf")
            do {
                _ = try TwoUpSplitter.split(pdfURL: url, outputURL: outputURL)
                return outputURL
            } catch {
                // Swallow here; the caller decides on fallback. A
                // toast/alert in the UI would be nicer follow-up,
                // but the sheet auto-dismisses when the phase
                // returns to .idle so a separate error surface
                // would need its own state.
                return nil
            }
        }.value
    }
}
