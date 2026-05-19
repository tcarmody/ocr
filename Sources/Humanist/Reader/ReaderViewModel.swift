import Foundation
import SwiftUI
import EPUB

/// R-Reader. Per-window state for the EPUB reader scene.
///
/// Loads the EPUB into an in-memory `EPUBBook`, walks the spine,
/// surfaces the current chapter as a file URL the reader's
/// embedded WKWebView can load directly. No editor coupling — the
/// reader reads from disk only; "Edit Source…" hands off to the
/// existing editor scene via `openWindow(id:value:)`.
@MainActor
final class ReaderViewModel: ObservableObject {

    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: LoadState = .loading
    /// In-memory model of the open EPUB. Owns the working
    /// directory's lifecycle (cleaned up on deinit unless ownership
    /// is reassigned — none of the reader's paths do that).
    @Published private(set) var book: EPUBBook?
    /// Parsed table of contents for the sidebar. Built once on
    /// load. Always populated when the book has at least one
    /// readable spine item (the parser falls back to spine
    /// filenames so the sidebar never goes blank).
    @Published private(set) var toc: ReaderTOC = ReaderTOC(entries: [])
    /// Zero-based position in the spine. Drives the chapter URL,
    /// prev/next button enablement, and (in a follow-up) the
    /// reading-position sidecar.
    @Published private(set) var spineIndex: Int = 0
    /// Bumps each time the reader requests a chapter re-load — the
    /// embedded WKWebView observes this through `WebReaderPane` so
    /// font-size changes / future theme changes trigger a refresh
    /// without changing the URL.
    @Published private(set) var reloadTrigger: Int = 0

    let epubURL: URL

    init(epubURL: URL) {
        self.epubURL = epubURL
        Task { await load() }
    }

    /// Open + parse the EPUB. Failure surfaces in `state.failed`;
    /// the reader view renders an error placeholder.
    func load() async {
        let url = epubURL
        do {
            let opened = try await Task.detached(priority: .userInitiated) {
                try EPUBBook.open(epubURL: url)
            }.value
            self.book = opened
            self.toc = ReaderTOC.build(from: opened)
            self.spineIndex = 0
            self.state = .ready
        } catch {
            self.state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Spine navigation

    /// Absolute URL on disk of the currently-selected spine chapter,
    /// or nil when the book isn't ready / the spine is empty.
    var currentChapterURL: URL? {
        guard let book, !book.spine.isEmpty,
              spineIndex >= 0, spineIndex < book.spine.count
        else { return nil }
        let resourceID = book.spine[spineIndex]
        guard let resource = book.resourcesByID[resourceID] else { return nil }
        return book.absoluteURL(for: resource)
    }

    /// Human-readable title of the current chapter for the toolbar.
    /// Prefers the TOC's title when the current spine index has
    /// one; falls back to the filename stem otherwise.
    var currentChapterLabel: String {
        if let entry = toc.entries.first(where: { $0.spineIndex == spineIndex }) {
            return entry.title
        }
        guard let book, !book.spine.isEmpty,
              spineIndex >= 0, spineIndex < book.spine.count
        else { return "" }
        let resourceID = book.spine[spineIndex]
        if let resource = book.resourcesByID[resourceID] {
            return (resource.hrefRelativeToOPF as NSString)
                .lastPathComponent
                .replacingOccurrences(of: ".xhtml", with: "")
                .replacingOccurrences(of: ".html", with: "")
        }
        return "Chapter \(spineIndex + 1)"
    }

    var canGoPrevious: Bool {
        guard let book else { return false }
        return !book.spine.isEmpty && spineIndex > 0
    }

    var canGoNext: Bool {
        guard let book else { return false }
        return !book.spine.isEmpty && spineIndex < book.spine.count - 1
    }

    func previousChapter() {
        guard canGoPrevious else { return }
        spineIndex -= 1
        reloadTrigger += 1
    }

    func nextChapter() {
        guard canGoNext else { return }
        spineIndex += 1
        reloadTrigger += 1
    }

    /// Jump to an arbitrary spine index. Clamped to the valid range
    /// so a stale TOC entry or restored position past the spine end
    /// lands somewhere sensible rather than crashing. Bumps the
    /// reload trigger so the WKWebView re-loads even when the
    /// target is the current chapter (used by "Start of Chapter"
    /// scroll-reset behavior).
    func jump(toSpineIndex idx: Int) {
        guard let book, !book.spine.isEmpty else { return }
        let clamped = max(0, min(idx, book.spine.count - 1))
        spineIndex = clamped
        reloadTrigger += 1
    }

    /// Window title shown in the toolbar / titlebar.
    var displayTitle: String {
        book?.displayTitle ?? epubURL.deletingPathExtension().lastPathComponent
    }
}
