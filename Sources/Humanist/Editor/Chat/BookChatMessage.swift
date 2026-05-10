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
///
/// `bookEpubURL` and `bookTitle` are populated for library-scope
/// citations (R-Chat-Graph-Lite). Per-book chat citations leave
/// them nil so the existing per-window navigation continues to
/// work unchanged.
struct BookChatCitation: Identifiable, Equatable, Hashable, Codable {
    let chapterIndex: Int
    let title: String
    let resourceID: String
    /// Source book for the citation. Nil for current-book chat
    /// (the editor already knows which book is open); non-nil for
    /// library-scope chat — a tap opens that book in a new editor.
    let bookEpubURL: URL?
    let bookTitle: String?

    var id: String {
        if let url = bookEpubURL {
            return "\(url.path)#\(chapterIndex)"
        }
        return "current#\(chapterIndex)"
    }

    init(
        chapterIndex: Int,
        title: String,
        resourceID: String,
        bookEpubURL: URL? = nil,
        bookTitle: String? = nil
    ) {
        self.chapterIndex = chapterIndex
        self.title = title
        self.resourceID = resourceID
        self.bookEpubURL = bookEpubURL
        self.bookTitle = bookTitle
    }

    /// Decode optional book fields so transcripts persisted before
    /// R-Chat-Graph-Lite still load.
    private enum CodingKeys: String, CodingKey {
        case chapterIndex, title, resourceID, bookEpubURL, bookTitle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.chapterIndex = try c.decode(Int.self, forKey: .chapterIndex)
        self.title = try c.decode(String.self, forKey: .title)
        self.resourceID = try c.decode(String.self, forKey: .resourceID)
        self.bookEpubURL = try c.decodeIfPresent(URL.self, forKey: .bookEpubURL)
        self.bookTitle = try c.decodeIfPresent(String.self, forKey: .bookTitle)
    }
}
