import XCTest
@testable import Pipeline
import Document

final class DocumentIngestTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc-ingest-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - txt

    func test_txt_blank_line_paragraphs() throws {
        let url = try writeFile("essay.txt", contents: """
            First paragraph
            with a soft wrap.

            Second paragraph.


            Third paragraph after extra blank line.
            """)
        let book = try DocumentIngest().ingest(from: url)
        XCTAssertEqual(book.title, "essay")
        XCTAssertEqual(book.chapters.count, 1)
        let blocks = book.chapters[0].blocks
        XCTAssertEqual(blocks.count, 3)
        let texts = blocks.map { paragraphText($0) }
        XCTAssertEqual(texts[0], "First paragraph with a soft wrap.")
        XCTAssertEqual(texts[1], "Second paragraph.")
        XCTAssertEqual(texts[2], "Third paragraph after extra blank line.")
    }

    func test_txt_single_paragraph_no_blanks() throws {
        let url = try writeFile("note.txt", contents: "Just one line of text.")
        let book = try DocumentIngest().ingest(from: url)
        XCTAssertEqual(book.chapters[0].blocks.count, 1)
        XCTAssertEqual(paragraphText(book.chapters[0].blocks[0]), "Just one line of text.")
    }

    // MARK: - md

    func test_md_atx_headings_promote_first_h1_to_title() throws {
        let url = try writeFile("post.md", contents: """
            # On Reading

            A book is a **portable garden**.

            ## Some Subsection

            With *italicised* prose.
            """)
        let book = try DocumentIngest().ingest(from: url)
        XCTAssertEqual(book.title, "On Reading")
        let blocks = book.chapters[0].blocks
        XCTAssertEqual(blocks.count, 4)

        guard case let .heading(l1, h1Runs) = blocks[0] else {
            return XCTFail("expected h1, got \(blocks[0])")
        }
        XCTAssertEqual(l1, 1)
        XCTAssertEqual(h1Runs.first?.text, "On Reading")

        guard case let .paragraph(p1Runs) = blocks[1] else {
            return XCTFail("expected paragraph, got \(blocks[1])")
        }
        XCTAssertEqual(p1Runs.map(\.text).joined(), "A book is a portable garden.")
        let bold = p1Runs.first(where: { $0.isBold })
        XCTAssertEqual(bold?.text, "portable garden")

        guard case let .heading(l2, h2Runs) = blocks[2] else {
            return XCTFail("expected h2, got \(blocks[2])")
        }
        XCTAssertEqual(l2, 2)
        XCTAssertEqual(h2Runs.first?.text, "Some Subsection")

        guard case let .paragraph(p2Runs) = blocks[3] else {
            return XCTFail("expected paragraph, got \(blocks[3])")
        }
        XCTAssertEqual(p2Runs.map(\.text).joined(), "With italicised prose.")
        let italic = p2Runs.first(where: { $0.isItalic })
        XCTAssertEqual(italic?.text, "italicised")
    }

    func test_md_no_h1_keeps_filename_title() throws {
        let url = try writeFile("plain.md", contents: """
            ## Skipping straight to h2

            Body.
            """)
        let book = try DocumentIngest().ingest(from: url)
        XCTAssertEqual(book.title, "plain")
    }

    func test_md_inline_emphasis_round_trips() {
        let runs = DocumentIngest().parseInlineMarkdown("a *one* b **two** c ***three*** d")
        let texts = runs.map(\.text)
        XCTAssertEqual(texts, ["a ", "one", " b ", "two", " c ", "three", " d"])
        // Spot-check the flags on the emphasized runs.
        XCTAssertTrue(runs[1].isItalic && !runs[1].isBold)   // *one*
        XCTAssertTrue(runs[3].isBold && !runs[3].isItalic)   // **two**
        XCTAssertTrue(runs[5].isBold && runs[5].isItalic)    // ***three***
    }

    // MARK: - rtf

    func test_rtf_walks_paragraphs_and_emphasis() throws {
        // Minimal RTF: two paragraphs, the second has an italic span.
        let rtf = """
        {\\rtf1\\ansi\\deff0
        {\\fonttbl{\\f0 Helvetica;}}
        \\f0\\fs24 Plain paragraph.\\par
        \\f0\\fs24 With \\i italic\\i0  middle.\\par
        }
        """
        let url = try writeFile("note.rtf", contents: rtf)
        let book = try DocumentIngest().ingest(from: url)
        let blocks = book.chapters[0].blocks
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(paragraphText(blocks[0]), "Plain paragraph.")
        guard case let .paragraph(runs) = blocks[1] else {
            return XCTFail("expected paragraph, got \(blocks[1])")
        }
        XCTAssertEqual(runs.map(\.text).joined(), "With italic middle.")
        let italic = runs.first(where: { $0.isItalic })
        XCTAssertEqual(italic?.text, "italic")
    }

    // MARK: - support detection

    func test_isSupported_recognizes_known_extensions() {
        XCTAssertTrue(DocumentIngest.isSupported(URL(fileURLWithPath: "/tmp/x.txt")))
        XCTAssertTrue(DocumentIngest.isSupported(URL(fileURLWithPath: "/tmp/x.md")))
        XCTAssertTrue(DocumentIngest.isSupported(URL(fileURLWithPath: "/tmp/x.markdown")))
        XCTAssertTrue(DocumentIngest.isSupported(URL(fileURLWithPath: "/tmp/x.rtf")))
        XCTAssertTrue(DocumentIngest.isSupported(URL(fileURLWithPath: "/tmp/x.MD")))   // case
        XCTAssertFalse(DocumentIngest.isSupported(URL(fileURLWithPath: "/tmp/x.pdf")))
        XCTAssertFalse(DocumentIngest.isSupported(URL(fileURLWithPath: "/tmp/x.docx")))
    }

    // MARK: - helpers

    private func writeFile(_ name: String, contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func paragraphText(_ block: Block) -> String {
        guard case let .paragraph(runs) = block else { return "<not a paragraph>" }
        return runs.map(\.text).joined()
    }
}
