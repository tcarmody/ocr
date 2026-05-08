import Foundation

/// One turn in a chat-with-the-book conversation. Stored
/// in-memory only for v1 — closing the editor window discards
/// the transcript. Persistence (per-EPUB sidecar) is a v2
/// addition.
struct BookChatMessage: Identifiable, Equatable {
    enum Role: String, Equatable {
        case user, assistant
    }

    let id = UUID()
    let role: Role
    let text: String
    /// Citations parsed out of the assistant's `[chapter:N]`
    /// markers. Empty for user turns and for assistant replies
    /// that didn't reference any chapters.
    var citations: [BookChatCitation] = []
}

/// One clickable citation on an assistant turn. `chapterIndex`
/// is the position in the book's spine; `resourceID` is the
/// stable EPUB manifest id (the chat pane uses that to ask the
/// editor view-model to select the chapter).
struct BookChatCitation: Identifiable, Equatable, Hashable {
    var id: Int { chapterIndex }
    let chapterIndex: Int
    let title: String
    let resourceID: String
}
