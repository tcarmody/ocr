import XCTest
@testable import EPUB

final class FootnoteBackLinkerTests: XCTestCase {

    // MARK: - Pattern 1: <sup>N</sup>

    func test_sup_tag_ref_is_linked() {
        let input = """
        <p>This sentence has a note<sup>3</sup> in it.</p>
        <aside id="fn-3"><p>The footnote text.</p></aside>
        """
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        XCTAssertTrue(result.rewritten.contains(
            ##"<a href="#fn-3" id="fn-ref-3" class="footnote-ref"><sup>3</sup></a>"##
        ))
        XCTAssertEqual(result.links.count, 1)
        XCTAssertEqual(result.links[0].pattern, .supTag)
    }

    // MARK: - Pattern 2: [N]

    func test_bracket_ref_wraps_only_the_digit() {
        let input = """
        <p>This sentence has a note[3] in it.</p>
        <aside id="fn-3"><p>The footnote text.</p></aside>
        """
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        // Brackets stay outside the anchor — wrapping just the digit
        // matches the standard EPUB convention.
        XCTAssertTrue(result.rewritten.contains(
            ##"[<a href="#fn-3" id="fn-ref-3" class="footnote-ref">3</a>]"##
        ))
        XCTAssertEqual(result.links[0].pattern, .bracket)
    }

    // MARK: - Pattern 3: word-adjacent digit

    func test_word_adjacent_digit_after_letter_is_linked() {
        let input = """
        <p>This sentence has a note3 in it.</p>
        <aside id="fn-3"><p>The footnote text.</p></aside>
        """
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        XCTAssertTrue(result.rewritten.contains(
            ##"note<a href="#fn-3" id="fn-ref-3" class="footnote-ref">3</a> in"##
        ))
        XCTAssertEqual(result.links[0].pattern, .wordAdjacent)
    }

    func test_word_adjacent_digit_after_period_is_linked() {
        let input = """
        <p>End of sentence.3 Next sentence begins.</p>
        <aside id="fn-3"><p>The footnote text.</p></aside>
        """
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        XCTAssertTrue(result.rewritten.contains(
            ##"sentence.<a href="#fn-3" id="fn-ref-3" class="footnote-ref">3</a> Next"##
        ))
    }

    // MARK: - Pattern 4: unicode superscript digits

    func test_unicode_superscript_ref_is_linked() {
        let input = """
        <p>This sentence has a note³ in it.</p>
        <aside id="fn-3"><p>The footnote text.</p></aside>
        """
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        XCTAssertTrue(result.rewritten.contains(
            ##"note<a href="#fn-3" id="fn-ref-3" class="footnote-ref">³</a> in"##
        ))
        XCTAssertEqual(result.links[0].pattern, .unicodeSup)
    }

    func test_multi_digit_unicode_superscript_decoded_correctly() {
        let input = """
        <p>Note¹² here.</p>
        <aside id="fn-12"><p>The footnote text.</p></aside>
        """
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        XCTAssertTrue(result.rewritten.contains(
            ##"Note<a href="#fn-12" id="fn-ref-12" class="footnote-ref">¹²</a>"##
        ))
    }

    // MARK: - Skip: digit preceded by digit

    func test_digit_inside_larger_number_is_not_linked() {
        let input = """
        <p>This was published in 1939 in Berlin.</p>
        <aside id="fn-3"><p>The footnote text.</p></aside>
        """
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        // 9 in "1939" matches fn-9? No def for fn-9.
        // 3 in "1939" preceded by digit → skipped by lookbehind.
        XCTAssertEqual(result.links.count, 0)
    }

    // MARK: - Skip: structure-word context

    func test_page_reference_is_not_linked() {
        let input = """
        <p>See page 3 for details.</p>
        <aside id="fn-3"><p>The footnote text.</p></aside>
        """
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        // "page 3" — word-adjacent doesn't fire (whitespace between
        // "page" and "3"), but if a different pattern picked it up
        // the structure-word check should reject. Either way: no
        // link.
        XCTAssertEqual(result.links.count, 0)
    }

    func test_chapter_reference_is_not_linked_even_word_adjacent() {
        // Chapter3 style — word-adjacent fires but the structure
        // word check rejects.
        let input = """
        <p>See Chapter3 for context.</p>
        <aside id="fn-3"><p>The footnote text.</p></aside>
        """
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        XCTAssertEqual(result.links.count, 0)
    }

    // MARK: - Skip: ref inside the aside itself

    func test_digit_inside_aside_body_does_not_self_link() {
        let input = """
        <p>This sentence has a note.</p>
        <aside id="fn-3"><p>This footnote (3) talks about the number 3.</p></aside>
        """
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        // The body has no real ref, so no link from it.
        // The two `3`s inside the aside should not be linked
        // (they're inside the excluded aside range).
        XCTAssertEqual(result.links.count, 0)
        XCTAssertEqual(result.rewritten, input)
    }

    // MARK: - Skip: already-linked refs

    func test_existing_anchor_is_not_re_linked() {
        let input = """
        <p>Already linked<a href="#fn-3"><sup>3</sup></a> ref.</p>
        <aside id="fn-3"><p>The footnote text.</p></aside>
        """
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        XCTAssertEqual(result.links.count, 0)
    }

    // MARK: - One ref per definition

    func test_only_first_body_occurrence_per_definition_is_linked() {
        let input = """
        <p>First mention<sup>3</sup> here. Second mention<sup>3</sup> later.</p>
        <aside id="fn-3"><p>The footnote text.</p></aside>
        """
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        XCTAssertEqual(result.links.count, 1)
        // The first `<sup>3</sup>` was wrapped; the second is
        // still bare.
        let firstRefRange = result.rewritten.range(of: #"id="fn-ref-3""#)
        XCTAssertNotNil(firstRefRange)
        // Only one occurrence in output.
        XCTAssertEqual(
            result.rewritten.components(separatedBy: #"id="fn-ref-3""#).count - 1,
            1
        )
    }

    // MARK: - Back-link insertion

    func test_back_link_is_inserted_before_aside_close() {
        let input = """
        <p>Note<sup>3</sup> here.</p>
        <aside id="fn-3"><p>The footnote text.</p></aside>
        """
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        XCTAssertTrue(result.rewritten.contains(
            ##"<a href="#fn-ref-3" class="footnote-backref">↩</a></aside>"##
        ))
    }

    func test_back_link_not_re_inserted_on_second_pass() {
        let input = """
        <p>Note<sup>3</sup> here.</p>
        <aside id="fn-3"><p>The footnote text.</p></aside>
        """
        let pass1 = FootnoteBackLinker.linkFootnotes(in: input)
        let pass2 = FootnoteBackLinker.linkFootnotes(in: pass1.rewritten)
        // The second pass finds no new refs (existing anchor
        // excludes the already-linked one). And the existing
        // back-link is already present, so insertBackLinks skips it.
        XCTAssertEqual(
            pass2.rewritten.components(separatedBy: "footnote-backref").count - 1,
            1
        )
    }

    // MARK: - No definitions

    func test_no_footnote_definitions_is_no_op() {
        let input = "<p>Just a digit 3 here, no footnotes.</p>"
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        XCTAssertEqual(result.rewritten, input)
        XCTAssertEqual(result.links, [])
    }

    // MARK: - Multiple definitions

    func test_multiple_definitions_each_get_linked() {
        let input = """
        <p>First<sup>1</sup> and second<sup>2</sup>.</p>
        <aside id="fn-1"><p>First note.</p></aside>
        <aside id="fn-2"><p>Second note.</p></aside>
        """
        let result = FootnoteBackLinker.linkFootnotes(in: input)
        XCTAssertEqual(result.links.count, 2)
        XCTAssertTrue(result.rewritten.contains(#"id="fn-ref-1""#))
        XCTAssertTrue(result.rewritten.contains(#"id="fn-ref-2""#))
    }
}
