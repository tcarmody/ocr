import XCTest
@testable import Pipeline

final class BodyTypeInjectorTests: XCTestCase {

    func test_inject_adds_attribute_when_body_has_none() {
        let input = """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <body>body content</body>
            </html>
            """
        let result = BodyTypeInjector.inject(label: "chapter", into: input)
        XCTAssertTrue(result.changed)
        XCTAssertFalse(result.preservedExistingLabel)
        XCTAssertTrue(result.xhtml.contains(#"<body epub:type="chapter">"#))
    }

    func test_inject_preserves_existing_epub_type() {
        // Publishers set epub:type deliberately; AFM's "appendix"
        // guess must not silently replace a publisher's "afterword"
        // label. Conservative posture.
        let input = #"<body epub:type="afterword">body</body>"#
        let result = BodyTypeInjector.inject(label: "appendix", into: input)
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.preservedExistingLabel)
        XCTAssertEqual(result.xhtml, input)
    }

    func test_inject_preserves_other_attributes_unchanged() {
        // xmlns:epub is on <html> so the injector doesn't add
        // another declaration — this test focuses on attribute
        // preservation only.
        let input = """
            <html xmlns:epub="http://www.idpf.org/2007/ops">
            <body class="cover" id="cover">cover</body>
            </html>
            """
        let result = BodyTypeInjector.inject(label: "cover", into: input)
        XCTAssertTrue(result.changed)
        // The new epub:type sits adjacent to <body; original attrs
        // trail untouched in their original order.
        XCTAssertTrue(result.xhtml.contains(#"<body epub:type="cover" class="cover" id="cover">"#))
    }

    func test_inject_adds_namespace_decl_when_missing() {
        // EPUB 3 requires xmlns:epub declared when epub:type is
        // used. If the doc lacks the declaration anywhere, the
        // injector emits it inline on <body> alongside the new
        // attribute.
        let input = """
            <html xmlns="http://www.w3.org/1999/xhtml">
            <body>body</body>
            </html>
            """
        let result = BodyTypeInjector.inject(label: "preface", into: input)
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.xhtml.contains(
            #"xmlns:epub="http://www.idpf.org/2007/ops""#
        ))
        XCTAssertTrue(result.xhtml.contains(#"epub:type="preface""#))
    }

    func test_inject_skips_namespace_decl_when_already_present() {
        // Avoid duplicating xmlns:epub when the doc already
        // declares it on <html>.
        let input = """
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <body>body</body>
            </html>
            """
        let result = BodyTypeInjector.inject(label: "introduction", into: input)
        // Only the original declaration should remain — the
        // injector shouldn't have added a second one to <body>.
        let occurrences = result.xhtml
            .components(separatedBy: "xmlns:epub").count - 1
        XCTAssertEqual(occurrences, 1,
            "xmlns:epub should be declared exactly once")
    }

    func test_inject_returns_unchanged_when_label_is_empty() {
        let input = "<body>body</body>"
        let result = BodyTypeInjector.inject(label: "   ", into: input)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.xhtml, input)
    }

    func test_inject_returns_unchanged_when_no_body_tag() {
        let input = "<html><head></head></html>"
        let result = BodyTypeInjector.inject(label: "chapter", into: input)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.xhtml, input)
    }

    func test_inject_is_case_insensitive_on_body_tag() {
        // Real-world EPUBs are XHTML (lowercase by spec) but the
        // injector tolerates HTML-style uppercase too. Original
        // case of the tag is preserved in the rewrite.
        let input = """
            <HTML xmlns:epub="http://www.idpf.org/2007/ops">
            <BODY>upper</BODY>
            </HTML>
            """
        let result = BodyTypeInjector.inject(label: "chapter", into: input)
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.xhtml.contains(#"<BODY epub:type="chapter">"#))
    }

    func test_inject_recognizes_uppercase_existing_attribute() {
        // EPUB:type (rare, but defensive) is still epub:type and
        // must trigger the preserve path.
        let input = #"<body EPUB:TYPE="afterword">body</body>"#
        let result = BodyTypeInjector.inject(label: "chapter", into: input)
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.preservedExistingLabel)
    }

    func test_inject_recognizes_whitespace_around_equals() {
        let input = #"<body epub:type = "afterword">body</body>"#
        let result = BodyTypeInjector.inject(label: "chapter", into: input)
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.preservedExistingLabel)
    }
}
