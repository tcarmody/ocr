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

    // MARK: - html

    func test_html_paragraphs_and_headings_round_trip() throws {
        let html = """
            <html><body>
            <h1>Top Title</h1>
            <p>First <em>italic</em> paragraph.</p>
            <h2>Sub</h2>
            <p>Body text with <strong>bold</strong> emphasis.</p>
            </body></html>
            """
        let url = try writeFile("page.html", contents: html)
        let book = try DocumentIngest().ingest(from: url)
        let blocks = book.chapters[0].blocks
        // NSAttributedString may emit a leading or trailing empty
        // paragraph from the body wrapper; filter for the cases we
        // care about.
        let headings = blocks.compactMap { block -> (Int, String)? in
            guard case let .heading(level, runs) = block else { return nil }
            return (level, runs.map(\.text).joined())
        }
        XCTAssertTrue(headings.contains(where: { $0.0 == 1 && $0.1 == "Top Title" }))
        XCTAssertTrue(headings.contains(where: { $0.0 == 2 && $0.1 == "Sub" }))

        let paragraphs = blocks.compactMap { block -> [InlineRun]? in
            guard case let .paragraph(runs) = block else { return nil }
            return runs
        }
        let firstPara = try XCTUnwrap(paragraphs.first {
            $0.map(\.text).joined().contains("italic")
        })
        XCTAssertTrue(firstPara.contains(where: { $0.text == "italic" && $0.isItalic }))

        let boldPara = try XCTUnwrap(paragraphs.first {
            $0.map(\.text).joined().contains("bold")
        })
        XCTAssertTrue(boldPara.contains(where: { $0.text == "bold" && $0.isBold }))
    }

    // MARK: - docx (round-trip via NSAttributedString.data)

    func test_docx_round_trip_preserves_paragraphs_and_emphasis() throws {
        // Build a docx fixture by serializing an NSAttributedString
        // we control end-to-end. This validates the full
        // round-trip without needing a real Word document fixture
        // checked into the repo.
        let body = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: 12)
        body.append(NSAttributedString(
            string: "Plain paragraph text.\n",
            attributes: [.font: baseFont]
        ))
        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        body.append(NSAttributedString(
            string: "Bold word",
            attributes: [.font: boldFont]
        ))
        body.append(NSAttributedString(
            string: " then plain.\n",
            attributes: [.font: baseFont]
        ))
        let docxData = try body.data(
            from: NSRange(location: 0, length: body.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        let url = tempDir.appendingPathComponent("doc.docx")
        try docxData.write(to: url)

        let book = try DocumentIngest().ingest(from: url)
        let blocks = book.chapters[0].blocks
        let paragraphs = blocks.compactMap { block -> [InlineRun]? in
            guard case let .paragraph(runs) = block else { return nil }
            return runs
        }
        XCTAssertGreaterThanOrEqual(paragraphs.count, 2)
        let plain = try XCTUnwrap(paragraphs.first(where: {
            $0.map(\.text).joined().contains("Plain paragraph")
        }))
        XCTAssertEqual(plain.map(\.text).joined(), "Plain paragraph text.")
        let mixed = try XCTUnwrap(paragraphs.first(where: {
            $0.map(\.text).joined().contains("Bold word")
        }))
        XCTAssertTrue(mixed.contains(where: { $0.text == "Bold word" && $0.isBold }))
    }

    // MARK: - support detection

    func test_isSupported_recognizes_known_extensions() {
        for ext in ["txt", "md", "markdown", "rtf", "html", "htm", "docx", "doc", "odt"] {
            XCTAssertTrue(
                DocumentIngest.isSupported(URL(fileURLWithPath: "/tmp/x.\(ext)")),
                "expected \(ext) to be supported"
            )
        }
        XCTAssertTrue(DocumentIngest.isSupported(URL(fileURLWithPath: "/tmp/x.MD")))   // case
        XCTAssertFalse(DocumentIngest.isSupported(URL(fileURLWithPath: "/tmp/x.pdf")))
        XCTAssertFalse(DocumentIngest.isSupported(URL(fileURLWithPath: "/tmp/x.epub")))
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
