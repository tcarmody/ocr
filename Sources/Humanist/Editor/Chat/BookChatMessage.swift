import Foundation

/// One turn in a chat-with-the-book conversation. Persisted via
/// `ChatTranscriptStore` keyed by EPUB source URL — survives
/// editor close + reopen.
struct BookChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Equatable, Codable {
        case user, assistant
    }

    var id: UUID
    let role: Role
    var text: String
    /// Citations parsed out of the assistant's `[chapter:N]`
    /// markers. Empty for user turns and for assistant replies
    /// that didn't reference any chapters.
    var citations: [BookChatCitation]
    /// When the message was created. Drives ordering on load and
    /// gives the UI somewhere to show "(2 minutes ago)" later if
    /// we want it.
    var createdAt: Date

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        citations: [BookChatCitation] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.citations = citations
        self.createdAt = createdAt
    }
}

/// One clickable citation on an assistant turn. `chapterIndex`
/// is the position in the book's spine; `resourceID` is the
/// stable EPUB manifest id (the chat pane uses that to ask the
/// editor view-model to select the chapter).
struct BookChatCitation: Identifiable, Equatable, Hashable, Codable {
    var id: Int { chapterIndex }
    let chapterIndex: Int
    let title: String
    let resourceID: String
}
