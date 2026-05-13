import XCTest
import PDFKit
import CoreGraphics
@testable import PDFIngest

/// Coverage for `PDFOutlineExtractor` — walks the synthetic PDFs
/// built in `setUp` to exercise the flatten / depth-cap / page-
/// resolution logic without committing real-world fixture files.
final class PDFOutlineExtractorTests: XCTestCase {

    // MARK: - Empty / no outline

    func test_empty_outline_returns_empty_list() {
        let doc = makeBlankDoc(pageCount: 3)
        // doc.outlineRoot is nil by default.
        XCTAssertEqual(PDFOutlineExtractor.extract(from: doc), [])
    }

    func test_outline_root_with_no_children_returns_empty_list() {
        let doc = makeBlankDoc(pageCount: 3)
        doc.outlineRoot = PDFOutline()
        XCTAssertEqual(PDFOutlineExtractor.extract(from: doc), [])
    }

    // MARK: - Flat outline

    func test_flat_outline_extracted_in_document_order() {
        let doc = makeBlankDoc(pageCount: 5)
        let root = PDFOutline()
        attachBookmark(to: root, label: "Chapter 1", pageIndex: 0, in: doc)
        attachBookmark(to: root, label: "Chapter 2", pageIndex: 2, in: doc)
        attachBookmark(to: root, label: "Chapter 3", pageIndex: 4, in: doc)
        doc.outlineRoot = root

        let entries = PDFOutlineExtractor.extract(from: doc)
        XCTAssertEqual(entries.map(\.title), ["Chapter 1", "Chapter 2", "Chapter 3"])
        XCTAssertEqual(entries.map(\.pdfPage), [0, 2, 4])
    }

    // MARK: - Nested outline

    /// Outline tree:
    ///   Part I
    ///     Chapter 1
    ///     Chapter 2
    ///   Part II
    ///     Chapter 3
    /// All four entries should land — depth 1 (Parts) and depth 2
    /// (Chapters) both fit under maxDepth = 2.
    func test_two_level_nesting_keeps_both_levels() {
        let doc = makeBlankDoc(pageCount: 10)
        let root = PDFOutline()
        let partI = attachBookmark(to: root, label: "Part I", pageIndex: 0, in: doc)
        attachBookmark(to: partI, label: "Chapter 1", pageIndex: 1, in: doc)
        attachBookmark(to: partI, label: "Chapter 2", pageIndex: 3, in: doc)
        let partII = attachBookmark(to: root, label: "Part II", pageIndex: 5, in: doc)
        attachBookmark(to: partII, label: "Chapter 3", pageIndex: 6, in: doc)
        doc.outlineRoot = root

        let entries = PDFOutlineExtractor.extract(from: doc)
        XCTAssertEqual(entries.map(\.title), [
            "Part I", "Chapter 1", "Chapter 2", "Part II", "Chapter 3"
        ])
    }

    /// Outline tree:
    ///   Chapter 1
    ///     Section 1.1
    ///       Subsection 1.1.1  ← depth 3, dropped
    /// The extractor caps at maxDepth = 2, so the subsection is
    /// skipped to avoid shattering chapters into sub-chunks.
    func test_depth_cap_drops_subsections() {
        let doc = makeBlankDoc(pageCount: 5)
        let root = PDFOutline()
        let ch1 = attachBookmark(to: root, label: "Chapter 1", pageIndex: 0, in: doc)
        let sec = attachBookmark(to: ch1, label: "Section 1.1", pageIndex: 1, in: doc)
        attachBookmark(to: sec, label: "Subsection 1.1.1", pageIndex: 2, in: doc)
        doc.outlineRoot = root

        let entries = PDFOutlineExtractor.extract(from: doc)
        XCTAssertEqual(entries.map(\.title), ["Chapter 1", "Section 1.1"])
    }

    // MARK: - Filtering

    func test_blank_label_entries_dropped() {
        let doc = makeBlankDoc(pageCount: 3)
        let root = PDFOutline()
        attachBookmark(to: root, label: "Real Chapter", pageIndex: 0, in: doc)
        attachBookmark(to: root, label: "   ", pageIndex: 1, in: doc)  // blank
        attachBookmark(to: root, label: "Another Real", pageIndex: 2, in: doc)
        doc.outlineRoot = root

        let entries = PDFOutlineExtractor.extract(from: doc)
        XCTAssertEqual(entries.map(\.title), ["Real Chapter", "Another Real"])
    }

    func test_entries_without_destination_dropped() {
        let doc = makeBlankDoc(pageCount: 3)
        let root = PDFOutline()
        attachBookmark(to: root, label: "Real Chapter", pageIndex: 0, in: doc)
        // Bookmark with no destination — sometimes used for
        // grouping in publisher trees.
        let orphan = PDFOutline()
        orphan.label = "No Destination"
        root.insertChild(orphan, at: root.numberOfChildren)
        doc.outlineRoot = root

        let entries = PDFOutlineExtractor.extract(from: doc)
        XCTAssertEqual(entries.map(\.title), ["Real Chapter"])
    }

    // MARK: - Helpers

    private func makeBlankDoc(pageCount: Int) -> PDFDocument {
        let doc = PDFDocument()
        for i in 0..<pageCount {
            let page = PDFPage()
            doc.insert(page, at: i)
        }
        return doc
    }

    @discardableResult
    private func attachBookmark(
        to parent: PDFOutline,
        label: String,
        pageIndex: Int,
        in doc: PDFDocument
    ) -> PDFOutline {
        let child = PDFOutline()
        child.label = label
        if let page = doc.page(at: pageIndex) {
            child.destination = PDFDestination(page: page, at: CGPoint.zero)
        }
        parent.insertChild(child, at: parent.numberOfChildren)
        return child
    }
}
