import Foundation
import Document
import OCR
import Pipeline
import EPUB

/// Coordinator for the V-Refresh "Re-OCR All Pages" flow. Walks the
/// page map, replaces each page's body in the source XHTML with a
/// fresh OCR pass through the chosen engine, preserves user-edited
/// pages (snapshot-fingerprint check), and saves the book.
///
/// Lives separately from `EditorViewModel` so the VM stays focused
/// on file/buffer/save state. Holds a weak reference back to the VM
/// for the few cross-cutting reads (book / pageMap / sourcePDFURL /
/// language picker) and for the post-save view refresh callbacks.
@MainActor
final class BulkReOCRCoordinator: ObservableObject {
    /// Progress + completion state for an in-flight run. Set
    /// non-nil at start, nil after dismiss. The view binds a sheet
    /// to its presence; `completedPages / totalPages` drives the
    /// progress bar.
    @Published var progress: Progress?

    /// User-confirmation sheet state. Bulk Re-OCR overwrites every
    /// chapter file's page bodies — non-trivial scope, so we
    /// confirm before starting.
    @Published var confirmation: Confirmation?

    private weak var vm: EditorViewModel?
    private var task: Task<Void, Never>?

    init(vm: EditorViewModel) {
        self.vm = vm
    }

    struct Progress: Identifiable, Equatable {
        let id = UUID()
        let totalPages: Int
        var completedPages: Int = 0
        /// Pages skipped because the user had manually edited them
        /// since the last automated pass (V-Refresh v2 protection).
        /// Counted toward `completedPages` so the progress bar fills
        /// to 100%, but reported separately so the user knows what
        /// was preserved.
        var preservedPages: Int = 0
        var currentPDFPage: Int?
        var engineDisplayName: String
        var failures: [PageFailure] = []
        var isFinished: Bool = false

        struct PageFailure: Equatable {
            let pdfPage: Int
            let message: String
        }
    }

    struct Confirmation: Identifiable, Equatable {
        let id = UUID()
        let engine: ReOCREngineKind
        let pageCount: Int
    }

    /// Show the confirmation sheet for a bulk run with the chosen
    /// engine. The sheet's OK action calls `run(engine:)`.
    /// Pre-flight: verifies a source PDF is attached, the page map
    /// exists, and the engine is installed; otherwise surfaces an
    /// error via the VM's `chapterOperationError` instead of opening
    /// the sheet.
    func confirm(engine kind: ReOCREngineKind) {
        guard let vm else { return }
        guard vm.sourcePDFURL != nil else {
            vm.chapterOperationError = "No source PDF is attached. Use 'Attach Source PDF…' first."
            return
        }
        guard let map = vm.pageMap, !map.entries.isEmpty else {
            vm.chapterOperationError = "This EPUB has no page map sidecar — bulk Re-OCR can only run on EPUBs Humanist itself produced."
            return
        }
        guard kind.isAvailable else {
            vm.chapterOperationError = "\(kind.displayName) is not installed on this machine."
            return
        }
        confirmation = Confirmation(
            engine: kind, pageCount: map.entries.count
        )
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    /// Run the bulk re-OCR on every page in the page map. Mutates
    /// each page's body in `Resource.text` directly (same splice
    /// rule the per-page Re-OCR sheet's "Replace in Source" uses),
    /// then saves the book. User cancellation aborts the loop;
    /// whatever was completed stays in memory.
    func run(engine kind: ReOCREngineKind) {
        guard task == nil else { return }
        confirmation = nil
        task = Task { [weak self] in
            await self?.perform(engine: kind)
        }
    }

    /// Cancel an in-flight run. Pages already completed stay
    /// mutated in memory; the user can save or close-without-saving
    /// to revert. The progress sheet stays open until the task
    /// notices the cancel and clears the state.
    func cancel() {
        task?.cancel()
    }

    /// Dismiss the progress sheet after the run finishes. Called by
    /// the sheet's "Done" button.
    func dismissProgress() {
        progress = nil
    }

    private func perform(engine kind: ReOCREngineKind) async {
        guard let vm,
              let book = vm.book,
              let map = vm.pageMap,
              let sourcePDF = vm.sourcePDFURL,
              let engine = kind.makeEngine()
        else { return }

        let entries = map.entries.sorted { $0.pdfPage < $1.pdfPage }
        progress = Progress(
            totalPages: entries.count,
            engineDisplayName: kind.displayName
        )

        let pipeline = PDFToEPUBPipeline()
        let langs = vm.languagesForReOCR()
        let docLanguage = book.metadata.language
            .flatMap { BCP47(rawValue: $0) } ?? langs.first ?? .en

        // V-Refresh v2: load existing snapshots. When a page's
        // current body fingerprint differs from the snapshot, the
        // user has edited it since the last automated pass — we
        // preserve their edits and skip the page. Books without a
        // snapshot sidecar (legacy / pre-v2) get treated as "no
        // edits to protect"; the first run writes fresh snapshots
        // so subsequent runs preserve any edits made in between.
        var snapshots = PageSnapshots.read(workingDirectory: book.workingDirectory)
            ?? PageSnapshots()

        var successCount = 0
        for entry in entries {
            if Task.isCancelled { break }
            progress?.currentPDFPage = entry.pdfPage

            let chapterURL = book.workingDirectory
                .appendingPathComponent(entry.xhtmlFile)
                .canonicalForFile
            guard let resource = book.resource(at: chapterURL),
                  let chapterText = resource.text,
                  let currentBody = PageContentReplacer.body(
                      of: entry.anchorId, in: chapterText
                  )
            else {
                progress?.failures.append(.init(
                    pdfPage: entry.pdfPage,
                    message: "Anchor \(entry.anchorId) not found in \(entry.xhtmlFile)."
                ))
                progress?.completedPages += 1
                continue
            }

            let currentFingerprint = PageSnapshots.fingerprint(of: currentBody)
            if let recorded = snapshots.fingerprintByAnchor[entry.anchorId],
               recorded != currentFingerprint {
                progress?.preservedPages += 1
                progress?.completedPages += 1
                continue
            }

            do {
                let result = try await pipeline.reOCRSinglePage(
                    pdfURL: sourcePDF,
                    pageIndex: entry.pdfPage,
                    engine: engine,
                    languages: langs
                )
                let bodyBlocks = result.blocks.filter {
                    if case .anchor = $0 { return false } else { return true }
                }
                let xhtml = XHTMLFragmentRenderer.render(
                    blocks: bodyBlocks, language: docLanguage
                )
                guard let newText = PageContentReplacer.replaceBody(
                    of: entry.anchorId, in: chapterText, with: xhtml
                ) else {
                    progress?.failures.append(.init(
                        pdfPage: entry.pdfPage,
                        message: "Failed to splice page \(entry.anchorId) into \(entry.xhtmlFile)."
                    ))
                    progress?.completedPages += 1
                    continue
                }
                resource.text = newText
                if let newBody = PageContentReplacer.body(
                    of: entry.anchorId, in: newText
                ) {
                    snapshots.fingerprintByAnchor[entry.anchorId] =
                        PageSnapshots.fingerprint(of: newBody)
                }
                successCount += 1
            } catch {
                progress?.failures.append(.init(
                    pdfPage: entry.pdfPage,
                    message: error.localizedDescription
                ))
            }
            progress?.completedPages += 1
        }

        // Save what we did (cancelled or not — partial results
        // belong on disk so a re-run can pick up from there). Skip
        // when zero pages succeeded so we don't bump
        // dcterms:modified for a no-op.
        if successCount > 0 {
            do {
                try EPUBBookSaver().save(book)
                try? snapshots.write(workingDirectory: book.workingDirectory)
                vm.didCompleteBulkReOCR()
            } catch {
                progress?.failures.append(.init(
                    pdfPage: -1,
                    message: "Save failed: \(error.localizedDescription)"
                ))
            }
        }

        progress?.isFinished = true
        progress?.currentPDFPage = nil
        task = nil
    }
}
