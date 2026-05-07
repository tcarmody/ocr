import XCTest
@testable import Humanist

/// `BookCSSBuilder` — pure CSS render / parse. The viewmodel +
/// sheet are wired separately; here we check the file-level
/// round-trip that has to be byte-stable for sentinel parsing on
/// next open.
final class BookStyleTests: XCTestCase {

    // MARK: - render

    func test_apply_emits_block_with_sentinel() {
        let style = BookStyle(font: .sans, fontSize: 1.2, theme: .sepia)
        let css = BookCSSBuilder.apply(style: style, to: nil)
        XCTAssertTrue(css.contains(BookCSSBuilder.blockStart))
        XCTAssertTrue(css.contains(BookCSSBuilder.blockEnd))
        XCTAssertTrue(css.contains("humanist-style:"))
        XCTAssertTrue(css.contains("font-family: -apple-system"),
            "sans theme should use the system stack")
        XCTAssertTrue(css.contains("font-size: 1.2em"),
            "fontSize 1.2 should render as 1.2em")
        XCTAssertTrue(css.contains("background: #f4ecd8"),
            "sepia theme background should be cream")
    }

    func test_apply_preserves_existing_user_css() {
        let user = """
            /* my custom rules */
            body { letter-spacing: 0.02em; }
            .pullquote { color: #888; }
            """
        let css = BookCSSBuilder.apply(style: .default, to: user)
        XCTAssertTrue(css.contains("letter-spacing: 0.02em"),
            "user-authored rules above the style block must be preserved")
        XCTAssertTrue(css.contains(".pullquote { color: #888; }"))
    }

    func test_apply_replaces_previous_style_block() {
        // Two consecutive applies should leave exactly one style
        // block in the output, not stack them up.
        let first = BookCSSBuilder.apply(
            style: BookStyle(font: .serif, fontSize: 1.0, theme: .light),
            to: nil
        )
        let second = BookCSSBuilder.apply(
            style: BookStyle(font: .sans, fontSize: 1.3, theme: .dark),
            to: first
        )
        let startCount = second.components(separatedBy: BookCSSBuilder.blockStart).count - 1
        let endCount = second.components(separatedBy: BookCSSBuilder.blockEnd).count - 1
        XCTAssertEqual(startCount, 1, "should have exactly one style start sentinel")
        XCTAssertEqual(endCount, 1, "should have exactly one style end sentinel")
        XCTAssertTrue(second.contains("font-size: 1.3em"))
        XCTAssertTrue(second.contains("background: #1e1e1e"))
        XCTAssertFalse(second.contains("background: #ffffff"),
            "previous light-theme bg must not survive the rewrite")
    }

    // MARK: - parse

    func test_parse_recovers_full_style() {
        let original = BookStyle(font: .monospace, fontSize: 0.85, theme: .dark)
        let css = BookCSSBuilder.apply(style: original, to: nil)
        let recovered = BookCSSBuilder.parse(css)
        XCTAssertEqual(recovered, original)
    }

    func test_parse_returns_nil_for_unstyled_css() {
        // No sentinel = un-styled book (or pre-R-Custom-Styles EPUB).
        let css = BookCSSBuilder.defaultBaseCSS
        XCTAssertNil(BookCSSBuilder.parse(css))
    }

    func test_parse_returns_nil_for_malformed_sentinel() {
        let css = """
            body { color: red; }
            /* humanist-style: not-json */
            """
        XCTAssertNil(BookCSSBuilder.parse(css))
    }

    func test_round_trip_through_apply_then_parse() {
        // For every combination of font + theme at a representative
        // size, applying then parsing must return the same style —
        // any divergence would break "open EPUB shows my last style"
        // on the next launch.
        let sizes: [Double] = [0.75, 1.0, 1.25, 1.5]
        for font in BookStyle.FontFamily.allCases {
            for theme in BookStyle.Theme.allCases {
                for size in sizes {
                    let style = BookStyle(font: font, fontSize: size, theme: theme)
                    let css = BookCSSBuilder.apply(style: style, to: nil)
                    let recovered = BookCSSBuilder.parse(css)
                    XCTAssertEqual(recovered, style,
                        "round-trip failed for font=\(font) theme=\(theme) size=\(size)")
                }
            }
        }
    }

    // MARK: - format helpers

    func test_formatSize_clamps_extremes() {
        // Out-of-range sizes shouldn't make it into the CSS;
        // unreadable output isn't worth catering to.
        XCTAssertEqual(BookCSSBuilder.formatSize(0.1), "0.5em")
        XCTAssertEqual(BookCSSBuilder.formatSize(5.0), "2em")
        XCTAssertEqual(BookCSSBuilder.formatSize(1.0), "1em",
            "whole numbers render without trailing decimals")
        XCTAssertEqual(BookCSSBuilder.formatSize(1.25), "1.25em")
    }

    func test_themeColors_match_documented_palette() {
        XCTAssertEqual(BookCSSBuilder.themeColors(.light).0, "#ffffff")
        XCTAssertEqual(BookCSSBuilder.themeColors(.sepia).0, "#f4ecd8")
        XCTAssertEqual(BookCSSBuilder.themeColors(.dark).1, "#d6d6d6")
    }
}
