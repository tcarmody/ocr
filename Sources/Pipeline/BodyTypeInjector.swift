import Foundation

/// R-EPUB-Import: write a chapter's classifier-emitted `epub:type`
/// label into the `<body>` opening tag of an existing XHTML
/// resource. Companion to `ParagraphAnchorInjector` — both are
/// minimal-disruption XHTML rewriters that the importer runs on
/// each spine resource.
///
/// Conservative semantics: an existing `epub:type` attribute on
/// `<body>` is *preserved*, not overwritten. Publishers set this
/// deliberately for back matter / appendices / glossaries, and a
/// machine-learning classifier's "appendix" guess shouldn't
/// silently replace a publisher's "afterword" label.
///
/// `xmlns:epub` namespace: the EPUB 3 spec requires the namespace
/// to be declared when `epub:type` is used. The conversion path's
/// `XHTMLWriter` declares it on `<html>`; imported books may or
/// may not have it. When the doc lacks the declaration anywhere
/// and we're adding a label, we emit it inline on `<body>` so the
/// result is always spec-valid.
public enum BodyTypeInjector {

    public struct Result: Sendable, Equatable {
        public let xhtml: String
        public let changed: Bool
        /// True when the body already carried a non-empty
        /// `epub:type` and the call was a no-op. Lets the caller
        /// surface "labeled by publisher" vs. "labeled by Humanist"
        /// stats if it wants to.
        public let preservedExistingLabel: Bool
    }

    /// Inject `epub:type="label"` into the `<body>` opening tag of
    /// `xhtml`. Returns the rewritten XHTML and a `changed` flag.
    /// No-op (returns the input unchanged + `changed: false`) when:
    ///  * `label` trims to empty;
    ///  * the body already carries an `epub:type` attribute;
    ///  * no `<body>` opening tag is found at all (malformed XHTML).
    public static func inject(
        label: String, into xhtml: String
    ) -> Result {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(xhtml: xhtml, changed: false,
                          preservedExistingLabel: false)
        }
        // Capture the `<body ...>` opening tag — the attribute
        // payload between `<body` and `>`. `\s` after `body` so
        // `<bodyguard>` (vanishingly unlikely but defensive)
        // doesn't match.
        let pattern = "<body\\b([^>]*)>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else {
            return Result(xhtml: xhtml, changed: false,
                          preservedExistingLabel: false)
        }
        let ns = xhtml as NSString
        guard let match = regex.firstMatch(
            in: xhtml,
            range: NSRange(location: 0, length: ns.length)
        ) else {
            return Result(xhtml: xhtml, changed: false,
                          preservedExistingLabel: false)
        }
        let attrRange = match.range(at: 1)
        let attrs = attrRange.location == NSNotFound
            ? ""
            : ns.substring(with: attrRange)
        if hasEPUBTypeAttribute(attrs) {
            return Result(xhtml: xhtml, changed: false,
                          preservedExistingLabel: true)
        }
        // Preserve the original opening-tag spelling (`<body>` vs
        // `<BODY>`) by slicing it off the match rather than
        // hardcoding lowercase. The full match is `<body...>`;
        // dropping the attribute payload + closing `>` leaves the
        // exact `<body` (or `<BODY`) prefix.
        let fullMatch = ns.substring(with: match.range)
        let tagOpenLength = fullMatch.count - attrs.count - 1  // drop attrs + ">"
        let tagOpen = (fullMatch as NSString)
            .substring(to: tagOpenLength)
        // Build the new attribute payload. Always prepend
        // `epub:type` (and the namespace decl when the doc lacks
        // one anywhere) so the new attribute sits adjacent to
        // `<body` and existing attrs trail unchanged.
        let needsNamespace = !xhtml.contains("xmlns:epub")
        let escapedLabel = escapeAttribute(trimmed)
        let prefix = needsNamespace
            ? " xmlns:epub=\"http://www.idpf.org/2007/ops\" epub:type=\"\(escapedLabel)\""
            : " epub:type=\"\(escapedLabel)\""
        let rebuilt = "\(tagOpen)\(prefix)\(attrs)>"
        let rewritten = ns.replacingCharacters(
            in: match.range, with: rebuilt
        )
        return Result(xhtml: rewritten, changed: true,
                      preservedExistingLabel: false)
    }

    /// Minimal attribute-value escape. The `SemanticChapterLabel`
    /// closed set is all lowercase alphabetic so escapes never
    /// fire in practice, but we still pass label strings through
    /// for hygiene + future-proofing if the label vocabulary grows.
    /// Inlined here (rather than reused from the EPUB module's
    /// internal `XMLEscape`) to keep the injector dependency-free.
    private static func escapeAttribute(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        return out
    }

    /// Same tolerant `id=`-style detection as
    /// `ParagraphAnchorInjector.hasIDAttribute` but keyed to
    /// `epub:type`. Word-boundary on the left so `data-epub:type=`
    /// (vanishingly unlikely) doesn't fool us; flexible
    /// whitespace around `=` so `epub:type ="x"` is recognized.
    private static func hasEPUBTypeAttribute(_ attrs: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: "(^|\\s)epub:type\\s*=",
            options: [.caseInsensitive]
        ) else { return false }
        let ns = attrs as NSString
        return regex.firstMatch(
            in: attrs,
            range: NSRange(location: 0, length: ns.length)
        ) != nil
    }
}

