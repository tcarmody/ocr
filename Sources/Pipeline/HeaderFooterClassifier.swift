import Foundation
import CoreGraphics
import OCR

/// Identify running headers, running footers, page numbers, and
/// footnote bodies across a multi-page document. Returns the set of
/// observations to drop.
///
/// Three complementary signals:
///
///   1. **Page-number rule.** An observation in the upper or lower 20%
///      of the page that is purely numeric, a roman numeral, or a short
///      string containing a digit (e.g. "p. 12", "— 12 —", "page 5") is
///      almost certainly a page number. Drop unconditionally.
///
///   2. **Position-clustered recurrence.** Group every observation by
///      `(normalized_text, y_band)` across all pages, where the
///      normalized text collapses runs of digits to `#` and y-bands
///      quantize the page into 20 strips. Anything whose cluster
///      appears on at least `minRecurrencePages` distinct pages is a
///      running head / footer regardless of absolute position. Drops
///      naturally cluster:
///        - `"304 Ethics: Subjectivity and Truth"` and
///          `"306 Ethics: Subjectivity and Truth"` both normalize to
///          `"# ethics: subjectivity and truth"`.
///        - `"What is Enlightenment? 305"` and `"What is Enlightenment? 307"`
///          both normalize to `"what is enlightenment? #"`.
///      The y-band requirement guards against body-text repetitions
///      (e.g. a recurring quote) by demanding the recurrence happens at
///      consistent vertical position.
///
///   3. **Footnote drop.** An observation in the lower
///      `footnoteZoneFraction` of the page whose first non-whitespace
///      character is a footnote marker (`*`, `†`, `‡`, `§`, `¶`) is
///      treated as a footnote starter. Everything visually at-or-below
///      that marker on the same page is dropped, since multi-line
///      footnotes wrap below the marker line. Real footnote linking
///      lives in Phase 5; for now we just keep them out of the body
///      flow so they don't shred paragraphs.
///
/// For documents below the recurrence threshold, only Rules 1 and 3 fire.
struct HeaderFooterClassifier {
    /// How many distinct pages a (text, y-band) cluster must appear on
    /// to be classified as a running head/footer.
    var minRecurrencePages: Int = 3
    /// Page divided into this many y bands. 20 → 5% per band.
    var yBandCount: Int = 20
    /// Loose top/bottom zone for the page-number rule.
    var pageNumberZoneFraction: CGFloat = 0.20
    /// Page-number-with-prefix max length (e.g. "p. 12", "page 5").
    var maxShortPageNumberLength: Int = 8
    /// Skip very short normalized strings when clustering — single
    /// characters and noise would over-cluster.
    var minNormalizedLengthForClustering: Int = 3
    /// Lower N% of the page within which a leading-marker observation
    /// triggers footnote-drop and cascades through everything below it.
    var footnoteZoneFraction: CGFloat = 0.30
    /// Characters that, when leading an observation in the footnote zone,
    /// mark the start of a footnote.
    static let footnoteMarkers: Set<Character> = ["*", "†", "‡", "§", "¶"]

    /// Why a particular observation was dropped. Surfaced in debug logs.
    enum DropReason: String, Sendable {
        case pageNumberZone        = "R1:pagenumber"
        case clusterRecurrence     = "R2:recurrence"
        case footnoteMarker        = "R3:footnote_marker"
        case footnoteCascade       = "R3:footnote_cascade"
    }

    struct Result: Sendable {
        var dropSet: Set<ObservationKey>
        var reasons: [ObservationKey: DropReason]
    }

    func classify(_ pages: [PageObservations]) -> Set<ObservationKey> {
        return classifyWithReasons(pages).dropSet
    }

    /// Same as `classify`, but also returns the per-key reason — useful
    /// for debug logging when output looks wrong.
    func classifyWithReasons(_ pages: [PageObservations]) -> Result {
        var drop = Set<ObservationKey>()
        var reasons: [ObservationKey: DropReason] = [:]

        func mark(_ key: ObservationKey, _ reason: DropReason) {
            drop.insert(key)
            // Don't downgrade an earlier-assigned reason.
            if reasons[key] == nil { reasons[key] = reason }
        }

        // Rule 1 — page numbers in the loose top/bottom zone.
        for page in pages {
            for (i, obs) in page.observations.enumerated() {
                guard inPageNumberZone(obs.box) else { continue }
                let trimmed = obs.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let containsDigit = trimmed.unicodeScalars.contains {
                    CharacterSet.decimalDigits.contains($0)
                }
                if Self.isPageNumberLike(trimmed) ||
                   (trimmed.count <= maxShortPageNumberLength && containsDigit) {
                    mark(.init(pageIndex: page.pageIndex, observationIndex: i), .pageNumberZone)
                }
            }
        }

        // Rule 3 — footnote drop. Find the topmost observation in the
        // footnote zone whose first non-whitespace character is a
        // footnote marker; drop it and everything visually below.
        for page in pages {
            var footnoteTopY: CGFloat? = nil
            var markerKey: ObservationKey? = nil
            for (i, obs) in page.observations.enumerated() {
                guard obs.box.midY < footnoteZoneFraction else { continue }
                let trimmed = obs.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let first = trimmed.first,
                      Self.footnoteMarkers.contains(first) else { continue }
                if footnoteTopY == nil || obs.box.midY > footnoteTopY! {
                    footnoteTopY = obs.box.midY
                    markerKey = .init(pageIndex: page.pageIndex, observationIndex: i)
                }
            }
            if let topY = footnoteTopY {
                for (i, obs) in page.observations.enumerated() {
                    let key = ObservationKey(pageIndex: page.pageIndex, observationIndex: i)
                    if obs.box.midY <= topY + 0.005 {
                        let reason: DropReason = (key == markerKey) ? .footnoteMarker : .footnoteCascade
                        mark(key, reason)
                    }
                }
            }
        }

        // Rule 2 — position-clustered recurrence.
        guard pages.count >= minRecurrencePages else {
            return Result(dropSet: drop, reasons: reasons)
        }

        struct Cluster: Hashable {
            let normalized: String
            let yBand: Int
        }
        var clusterKeys: [Cluster: [ObservationKey]] = [:]
        var pagesPerCluster: [Cluster: Set<Int>] = [:]

        for page in pages {
            for (i, obs) in page.observations.enumerated() {
                let key = ObservationKey(pageIndex: page.pageIndex, observationIndex: i)
                let trimmed = obs.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = Self.normalize(trimmed)
                guard normalized.count >= minNormalizedLengthForClustering else { continue }

                let yBand = max(0, min(yBandCount - 1,
                    Int(obs.box.midY * CGFloat(yBandCount))))
                let cluster = Cluster(normalized: normalized, yBand: yBand)
                clusterKeys[cluster, default: []].append(key)
                pagesPerCluster[cluster, default: []].insert(page.pageIndex)
            }
        }

        for (cluster, keys) in clusterKeys {
            let pageCount = pagesPerCluster[cluster]?.count ?? 0
            if pageCount >= minRecurrencePages {
                for key in keys { mark(key, .clusterRecurrence) }
            }
        }

        return Result(dropSet: drop, reasons: reasons)
    }

    private func inPageNumberZone(_ box: CGRect) -> Bool {
        box.midY > 1 - pageNumberZoneFraction || box.midY < pageNumberZoneFraction
    }

    // MARK: - normalization

    /// Cluster strings that vary only by their numeric content so that
    /// "Chapter 3 — Foo" and "Chapter 12 — Foo" both normalize to
    /// "chapter # — foo" and count as the same running head.
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var inDigits = false
        for ch in lowered {
            if ch.isNumber {
                if !inDigits {
                    out.append("#")
                    inDigits = true
                }
            } else {
                out.append(ch)
                inDigits = false
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True if the (already-trimmed) string is something we'd consider a
    /// page number on its own: arabic digits, roman numerals, or a small
    /// decoration like "— 12 —".
    static func isPageNumberLike(_ s: String) -> Bool {
        let stripped = s.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if stripped.isEmpty { return false }
        if stripped.allSatisfy(\.isNumber) { return true }
        if isRomanNumeral(stripped.lowercased()) { return true }
        return false
    }

    private static let romanCharSet = Set("ivxlcdm")
    private static func isRomanNumeral(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 12 else { return false }
        return s.allSatisfy { romanCharSet.contains($0) }
    }
}
