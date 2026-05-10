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
    /// Retrieval debug data captured at send time — per-hit
    /// score + rank breakdown for the paragraphs that produced
    /// this answer's context. Optional / decoded with
    /// `decodeIfPresent` so transcripts persisted before this
    /// field existed still load. Hidden by default in the UI;
    /// the chat pane has a toggle that reveals the per-message
    /// disclosure.
    var retrievalDetail: RetrievalDetail?
    /// Model-suggested follow-up questions parsed out of the
    /// `[follow-ups]…[/follow-ups]` block at the end of the
    /// response. Renders beneath the citation strip as one-click
    /// buttons that send the question as the next user turn.
    /// Empty / nil when the model didn't emit any (or when the
    /// transcript is from before this field existed).
    var suggestedFollowUps: [String]?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        citations: [BookChatCitation] = [],
        retrievalDetail: RetrievalDetail? = nil,
        suggestedFollowUps: [String]? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.citations = citations
        self.retrievalDetail = retrievalDetail
        self.suggestedFollowUps = suggestedFollowUps
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, citations
        case retrievalDetail, suggestedFollowUps, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.role = try c.decode(Role.self, forKey: .role)
        self.text = try c.decode(String.self, forKey: .text)
        self.citations = try c.decode([BookChatCitation].self, forKey: .citations)
        self.retrievalDetail = try c.decodeIfPresent(
            RetrievalDetail.self, forKey: .retrievalDetail
        )
        self.suggestedFollowUps = try c.decodeIfPresent(
            [String].self, forKey: .suggestedFollowUps
        )
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

/// Per-hit score + rank breakdown surfaced by the chat pane's
/// retrieval-debug toggle. Captured at send time for both per-
/// book and library scopes; the per-book scope leaves
/// `bookTitle` nil since the source is implicit in the active
/// editor window.
struct RetrievalDetail: Codable, Equatable {
    struct Hit: Codable, Equatable {
        let chapterIdx: Int
        let paragraphIdx: Int
        let bookTitle: String?
        let score: Double
        let bm25Rank: Int?
        let embeddingRank: Int?
        let hierarchyMatched: Bool
        let entityMatched: Bool
    }
    let hits: [Hit]
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
    /// Specific paragraph the model cited within the chapter, when
    /// the marker carried a `para:M` segment. The chip's tap
    /// handler routes to `EditorViewModel.requestParagraphScroll`
    /// when present so source + preview land on the cited
    /// paragraph rather than the chapter top. Nil when the model
    /// cited a chapter without a paragraph specifier (broader
    /// references like "the chapter on heterotopia").
    let paragraphIndex: Int?

    var id: String {
        let bookKey = bookEpubURL.map(\.path) ?? "current"
        let paraKey = paragraphIndex.map(String.init) ?? "-"
        return "\(bookKey)#\(chapterIndex)#\(paraKey)"
    }

    init(
        chapterIndex: Int,
        title: String,
        resourceID: String,
        bookEpubURL: URL? = nil,
        bookTitle: String? = nil,
        paragraphIndex: Int? = nil
    ) {
        self.chapterIndex = chapterIndex
        self.title = title
        self.resourceID = resourceID
        self.bookEpubURL = bookEpubURL
        self.bookTitle = bookTitle
        self.paragraphIndex = paragraphIndex
    }

    /// Decode optional book + paragraph fields so transcripts
    /// persisted before these landed still load.
    private enum CodingKeys: String, CodingKey {
        case chapterIndex, title, resourceID
        case bookEpubURL, bookTitle, paragraphIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.chapterIndex = try c.decode(Int.self, forKey: .chapterIndex)
        self.title = try c.decode(String.self, forKey: .title)
        self.resourceID = try c.decode(String.self, forKey: .resourceID)
        self.bookEpubURL = try c.decodeIfPresent(URL.self, forKey: .bookEpubURL)
        self.bookTitle = try c.decodeIfPresent(String.self, forKey: .bookTitle)
        self.paragraphIndex = try c.decodeIfPresent(
            Int.self, forKey: .paragraphIndex
        )
    }
}
