import XCTest
@testable import Humanist

final class ChatCitationFormatterTests: XCTestCase {

    // MARK: - single-citation format

    func test_chicago_with_author_title_chapter_para() {
        let citation = BookChatCitation(
            chapterIndex: 4,
            title: "On Power",
            resourceID: "ch05.xhtml",
            bookEpubURL: URL(fileURLWithPath: "/tmp/foucault.epub"),
            bookTitle: "Discipline and Punish",
            paragraphIndex: 11
        )
        let entry = makeEntry(
            title: "Discipline and Punish",
            author: "Michel Foucault"
        )
        let formatted = ChatCitationFormatter.format(
            citation: citation, entry: entry
        )
        XCTAssertEqual(
            formatted,
            "Michel Foucault, *Discipline and Punish*, “On Power”, ¶ 12."
        )
    }

    func test_chicago_without_author_uses_title_only() {
        let citation = BookChatCitation(
            chapterIndex: 0,
            title: "Preface",
            resourceID: "pref.xhtml",
            bookEpubURL: URL(fileURLWithPath: "/tmp/anon.epub"),
            bookTitle: "Anonymous Tract",
            paragraphIndex: nil
        )
        let entry = makeEntry(title: "Anonymous Tract", author: nil)
        let formatted = ChatCitationFormatter.format(
            citation: citation, entry: entry
        )
        XCTAssertEqual(formatted, "*Anonymous Tract*, “Preface”.")
    }

    func test_chicago_falls_back_to_chapter_number_when_title_empty() {
        let citation = BookChatCitation(
            chapterIndex: 3,
            title: "",
            resourceID: "ch04.xhtml",
            bookEpubURL: URL(fileURLWithPath: "/tmp/x.epub"),
            bookTitle: "Untitled",
            paragraphIndex: 5
        )
        let entry = makeEntry(title: "Untitled", author: "X")
        let formatted = ChatCitationFormatter.format(
            citation: citation, entry: entry
        )
        XCTAssertEqual(formatted, "X, *Untitled*, ch. 4, ¶ 6.")
    }

    func test_chicago_uses_citation_bookTitle_when_no_catalog_entry() {
        let citation = BookChatCitation(
            chapterIndex: 0,
            title: "Intro",
            resourceID: "intro.xhtml",
            bookEpubURL: URL(fileURLWithPath: "/tmp/missing.epub"),
            bookTitle: "Lost Book",
            paragraphIndex: 0
        )
        let formatted = ChatCitationFormatter.format(
            citation: citation, entry: nil
        )
        XCTAssertEqual(formatted, "*Lost Book*, “Intro”, ¶ 1.")
    }

    // MARK: - bibliography (offline path — no LibraryStore)

    @MainActor
    func test_bibliography_dedups_repeated_citations() {
        let url = URL(fileURLWithPath: "/tmp/foucault.epub")
        let same = BookChatCitation(
            chapterIndex: 4,
            title: "On Power",
            resourceID: "ch05.xhtml",
            bookEpubURL: url,
            bookTitle: "Discipline and Punish",
            paragraphIndex: 11
        )
        let result = ChatCitationFormatter.bibliography(
            citations: [same, same, same],
            library: nil
        )
        // One bullet only, even though we passed three copies.
        let lines = result.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("1. "))
    }

    @MainActor
    func test_bibliography_numbers_distinct_citations() {
        let a = BookChatCitation(
            chapterIndex: 0,
            title: "A",
            resourceID: "a.xhtml",
            bookEpubURL: URL(fileURLWithPath: "/tmp/a.epub"),
            bookTitle: "Book A",
            paragraphIndex: 0
        )
        let b = BookChatCitation(
            chapterIndex: 1,
            title: "B",
            resourceID: "b.xhtml",
            bookEpubURL: URL(fileURLWithPath: "/tmp/b.epub"),
            bookTitle: "Book B",
            paragraphIndex: nil
        )
        let result = ChatCitationFormatter.bibliography(
            citations: [a, b], library: nil
        )
        let lines = result.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("1. "))
        XCTAssertTrue(lines[1].hasPrefix("2. "))
    }

    // MARK: - transcript

    @MainActor
    func test_transcript_includes_user_and_assistant_turns_and_sources_section() {
        let user = BookChatMessage(role: .user, text: "What is biopolitics?")
        let assistantCitation = BookChatCitation(
            chapterIndex: 4,
            title: "On Power",
            resourceID: "ch05.xhtml",
            bookEpubURL: URL(fileURLWithPath: "/tmp/foucault.epub"),
            bookTitle: "Discipline and Punish",
            paragraphIndex: 11
        )
        let assistant = BookChatMessage(
            role: .assistant,
            text: "Biopolitics is …",
            citations: [assistantCitation]
        )
        let md = ChatCitationFormatter.transcript(
            messages: [user, assistant], library: nil
        )
        XCTAssertTrue(md.contains("## You"))
        XCTAssertTrue(md.contains("What is biopolitics?"))
        XCTAssertTrue(md.contains("## Assistant"))
        XCTAssertTrue(md.contains("Biopolitics is …"))
        // Footnote marker emitted under the assistant turn.
        XCTAssertTrue(md.contains("Sources: [^1]"))
        // Sources section at end with the formatted reference.
        XCTAssertTrue(md.contains("## Sources"))
        XCTAssertTrue(md.contains("[^1]: *Discipline and Punish*, “On Power”, ¶ 12."))
    }

    @MainActor
    func test_transcript_with_no_citations_skips_sources_section() {
        let user = BookChatMessage(role: .user, text: "Hi")
        let assistant = BookChatMessage(role: .assistant, text: "Hello")
        let md = ChatCitationFormatter.transcript(
            messages: [user, assistant], library: nil
        )
        XCTAssertFalse(md.contains("## Sources"))
        XCTAssertFalse(md.contains("[^"))
    }

    // MARK: - helpers

    private func makeEntry(title: String, author: String?) -> LibraryEntry {
        LibraryEntry(
            epubURL: URL(fileURLWithPath: "/tmp/dummy.epub"),
            title: title,
            languages: ["en"],
            addedAt: Date(),
            lastOpened: nil,
            conversionType: nil,
            author: author,
            genre: nil
        )
    }
}
