import XCTest
@testable import EPUB

final class LinkRewriterTests: XCTestCase {

    // MARK: - Path normalization

    func test_normalizePath_collapses_dot_segments() {
        XCTAssertEqual(LinkRewriter.normalizePath("text/./ch01.xhtml"), "text/ch01.xhtml")
        XCTAssertEqual(LinkRewriter.normalizePath("text/sub/../ch01.xhtml"), "text/ch01.xhtml")
        XCTAssertEqual(LinkRewriter.normalizePath("../../ch01.xhtml"), "ch01.xhtml")
    }

    func test_normalizePath_drops_empty_components() {
        XCTAssertEqual(LinkRewriter.normalizePath("text//ch01.xhtml"), "text/ch01.xhtml")
        XCTAssertEqual(LinkRewriter.normalizePath("/text/ch01.xhtml"), "text/ch01.xhtml")
    }

    // MARK: - Resolve relative

    func test_resolveRelative_same_directory() {
        XCTAssertEqual(
            LinkRewriter.resolveRelative(target: "ch02.xhtml", base: "text/ch01.xhtml"),
            "text/ch02.xhtml"
        )
    }

    func test_resolveRelative_parent_directory() {
        XCTAssertEqual(
            LinkRewriter.resolveRelative(target: "../images/fig.png", base: "text/ch01.xhtml"),
            "images/fig.png"
        )
    }

    func test_resolveRelative_top_level_base() {
        XCTAssertEqual(
            LinkRewriter.resolveRelative(target: "ch02.xhtml", base: "ch01.xhtml"),
            "ch02.xhtml"
        )
    }

    // MARK: - Relativize

    func test_relativize_same_directory() {
        XCTAssertEqual(
            LinkRewriter.relativize(target: "text/ch02.xhtml", base: "text/ch01.xhtml"),
            "ch02.xhtml"
        )
    }

    func test_relativize_target_in_sibling_directory() {
        XCTAssertEqual(
            LinkRewriter.relativize(target: "images/fig.png", base: "text/ch01.xhtml"),
            "../images/fig.png"
        )
    }

    func test_relativize_top_level_base() {
        XCTAssertEqual(
            LinkRewriter.relativize(target: "ch02.xhtml", base: "ch01.xhtml"),
            "ch02.xhtml"
        )
    }

    // MARK: - Fragment + external

    func test_splitFragment_separates_anchor() {
        let (target, fragment) = LinkRewriter.splitFragment("ch02.xhtml#section")
        XCTAssertEqual(target, "ch02.xhtml")
        XCTAssertEqual(fragment, "section")
    }

    func test_splitFragment_no_fragment() {
        let (target, fragment) = LinkRewriter.splitFragment("ch02.xhtml")
        XCTAssertEqual(target, "ch02.xhtml")
        XCTAssertEqual(fragment, "")
    }

    func test_isExternal_recognizes_http() {
        XCTAssertTrue(LinkRewriter.isExternal("http://example.com"))
        XCTAssertTrue(LinkRewriter.isExternal("https://example.com"))
        XCTAssertTrue(LinkRewriter.isExternal("mailto:foo@example.com"))
    }

    func test_isExternal_relative_path_is_internal() {
        XCTAssertFalse(LinkRewriter.isExternal("ch02.xhtml"))
        XCTAssertFalse(LinkRewriter.isExternal("../images/fig.png"))
    }

    // MARK: - rewriteHref

    func test_rewriteHref_same_directory_match() {
        let new = LinkRewriter.rewriteHref(
            "ch02.xhtml",
            baseHref: "text/ch01.xhtml",
            oldNormalized: "text/ch02.xhtml",
            newTargetHref: "text/ch02_renamed.xhtml"
        )
        XCTAssertEqual(new, "ch02_renamed.xhtml")
    }

    func test_rewriteHref_with_fragment_preserves_fragment() {
        let new = LinkRewriter.rewriteHref(
            "ch02.xhtml#sec1",
            baseHref: "text/ch01.xhtml",
            oldNormalized: "text/ch02.xhtml",
            newTargetHref: "text/ch02_renamed.xhtml"
        )
        XCTAssertEqual(new, "ch02_renamed.xhtml#sec1")
    }

    func test_rewriteHref_unrelated_target_returns_nil() {
        let new = LinkRewriter.rewriteHref(
            "ch99.xhtml",
            baseHref: "text/ch01.xhtml",
            oldNormalized: "text/ch02.xhtml",
            newTargetHref: "text/ch02_renamed.xhtml"
        )
        XCTAssertNil(new)
    }

    func test_rewriteHref_external_returns_nil() {
        let new = LinkRewriter.rewriteHref(
            "http://example.com",
            baseHref: "text/ch01.xhtml",
            oldNormalized: "text/ch02.xhtml",
            newTargetHref: "text/ch02_renamed.xhtml"
        )
        XCTAssertNil(new)
    }

    func test_rewriteHref_fragment_only_returns_nil() {
        let new = LinkRewriter.rewriteHref(
            "#section",
            baseHref: "text/ch01.xhtml",
            oldNormalized: "text/ch02.xhtml",
            newTargetHref: "text/ch02_renamed.xhtml"
        )
        XCTAssertNil(new)
    }

    func test_rewriteHref_cross_directory_match() {
        // base in `text/`, target moved from `text/ch02.xhtml` to a
        // sibling directory `chapters/intro.xhtml`. The rewritten
        // href should walk up out of `text/` and back down.
        let new = LinkRewriter.rewriteHref(
            "ch02.xhtml",
            baseHref: "text/ch01.xhtml",
            oldNormalized: "text/ch02.xhtml",
            newTargetHref: "chapters/intro.xhtml"
        )
        XCTAssertEqual(new, "../chapters/intro.xhtml")
    }

    // MARK: - rewrite (full pass)

    func test_rewrite_updates_anchor_href_and_image_src() {
        let xhtml = """
        <html><body>
        <p>See <a href="ch02.xhtml">chapter two</a>.</p>
        <p><img src="../images/fig.png" alt=""/></p>
        </body></html>
        """
        let result = LinkRewriter.rewrite(
            text: xhtml,
            baseHref: "text/ch01.xhtml",
            oldTargetHref: "text/ch02.xhtml",
            newTargetHref: "text/intro.xhtml"
        )
        XCTAssertEqual(result.changes, 1)
        XCTAssertTrue(result.text.contains("href=\"intro.xhtml\""))
        XCTAssertFalse(result.text.contains("href=\"ch02.xhtml\""))
        // The image's src wasn't a target match, so it's untouched.
        XCTAssertTrue(result.text.contains("src=\"../images/fig.png\""))
    }

    func test_rewrite_handles_single_quoted_attributes() {
        let xhtml = "<a href='ch02.xhtml'>two</a>"
        let result = LinkRewriter.rewrite(
            text: xhtml,
            baseHref: "text/ch01.xhtml",
            oldTargetHref: "text/ch02.xhtml",
            newTargetHref: "text/intro.xhtml"
        )
        XCTAssertEqual(result.changes, 1)
        XCTAssertTrue(result.text.contains("href='intro.xhtml'"))
    }

    func test_rewrite_no_matches_returns_zero() {
        let xhtml = "<a href=\"ch99.xhtml\">other</a>"
        let result = LinkRewriter.rewrite(
            text: xhtml,
            baseHref: "text/ch01.xhtml",
            oldTargetHref: "text/ch02.xhtml",
            newTargetHref: "text/intro.xhtml"
        )
        XCTAssertEqual(result.changes, 0)
        XCTAssertEqual(result.text, xhtml)
    }

    func test_rewrite_multiple_links_in_one_doc() {
        let xhtml = """
        <a href="ch02.xhtml">a</a>
        <a href="ch02.xhtml#s1">b</a>
        <a href="ch02.xhtml#s2">c</a>
        """
        let result = LinkRewriter.rewrite(
            text: xhtml,
            baseHref: "text/ch01.xhtml",
            oldTargetHref: "text/ch02.xhtml",
            newTargetHref: "text/intro.xhtml"
        )
        XCTAssertEqual(result.changes, 3)
        XCTAssertTrue(result.text.contains("href=\"intro.xhtml\""))
        XCTAssertTrue(result.text.contains("href=\"intro.xhtml#s1\""))
        XCTAssertTrue(result.text.contains("href=\"intro.xhtml#s2\""))
    }
}
