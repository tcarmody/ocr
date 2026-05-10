import Foundation

/// Retrieval scope for the chat-with-book pane.
///
/// `.currentBook` is the per-EPUB chat that R-Chat-Embeddings shipped:
/// retrieval reads the open book's BM25 + embedding indexes; citations
/// link to chapters within the editor window.
///
/// `.library` is the multi-book successor introduced by
/// R-Chat-Graph-Lite: retrieval scans every cataloged book that has
/// an embedding sidecar matching the current backend. Citations carry
/// the book in addition to the chapter and clicking opens a new
/// editor window on the cited book.
///
/// The choice is per-window — flipping the scope on one editor doesn't
/// affect chats running in others. A user can keep one window in
/// "current book" mode for close-reading and another in "library" mode
/// for cross-corpus questions.
enum ChatScope: String, CaseIterable, Identifiable, Sendable {
    case currentBook
    case library

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .currentBook: return "Current book"
        case .library:     return "Whole library"
        }
    }

    var blurb: String {
        switch self {
        case .currentBook:
            return "Retrieval scoped to this EPUB only — fast, focused, and the right default for close-reading."
        case .library:
            return "Retrieval spans every cataloged book with a sidecar matching the current embedding backend. Citations open the cited book in a new editor window."
        }
    }
}
