import Foundation
import CoreGraphics
import PDFKit

/// Pulls per-line text + bounding boxes out of a PDF's embedded text
/// layer (the selectable/copyable text under the visible glyphs).
///
/// Bounding boxes are normalized to Vision's convention: origin at
/// bottom-left, both axes in [0,1]. That makes the output drop-in
/// compatible with `OCR.TextObservation.box` so a downstream gap-filler
/// can compare embedded lines against Vision observations directly.
///
/// Two extraction paths are tried in order:
///   1. **Selection-based** — `PDFPage.selection(for:).selectionsByLine()`.
///      Fast and gives clean per-line bounds when it works.
///   2. **Character-based fallback** — iterate `page.numberOfCharacters`,
///      use `characterBounds(at:)` to get per-glyph positions, group by
///      y. Slower but works on PDFs where selection-by-line returns
///      degenerate or empty results.
///
/// Returns lines + diagnostic counts so callers can log what happened.
public struct EmbeddedTextExtractor {
    public init() {}

    public struct Line: Sendable, Equatable {
        public var text: String
        public var box: CGRect
        public init(text: String, box: CGRect) {
            self.text = text
            self.box = box
        }
    }

    /// Per-page diagnostics for debug logging.
    public struct Diagnostics: Sendable, Equatable {
        public var pageStringCharCount: Int
        public var selectionByLineCount: Int
        public var selectionByLineKept: Int
        public var characterFallbackUsed: Bool
        public var characterFallbackKept: Int
    }

    /// Convenience wrapper returning only the lines.
    public func extractLines(from pdf: LoadedPDF, pageIndex: Int) -> [Line] {
        extract(from: pdf, pageIndex: pageIndex).lines
    }

    public func extract(from pdf: LoadedPDF, pageIndex: Int) -> (lines: [Line], diagnostics: Diagnostics) {
        var diag = Diagnostics(
            pageStringCharCount: 0,
            selectionByLineCount: 0,
            selectionByLineKept: 0,
            characterFallbackUsed: false,
            characterFallbackKept: 0
        )

        guard pageIndex >= 0, pageIndex < pdf.pageCount,
              let page = pdf.document.page(at: pageIndex) else {
            return ([], diag)
        }
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return ([], diag) }

        diag.pageStringCharCount = page.string?.count ?? 0

        // Path 1 — selection-based.
        var lines: [Line] = []
        if let pageSelection = page.selection(for: pageRect) {
            let lineSels = pageSelection.selectionsByLine()
            diag.selectionByLineCount = lineSels.count
            for lineSel in lineSels {
                guard let raw = lineSel.string else { continue }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                let boundsInPage = lineSel.bounds(for: page)
                guard let normalized = normalize(boundsInPage, in: pageRect) else { continue }
                lines.append(Line(text: text, box: normalized))
            }
            diag.selectionByLineKept = lines.count
        }

        // Path 2 — character-based fallback. Triggered when selection
        // yielded nothing useful, even though page.string has content.
        if lines.isEmpty, diag.pageStringCharCount > 0 {
            diag.characterFallbackUsed = true
            lines = extractViaCharacters(page: page, pageRect: pageRect)
            diag.characterFallbackKept = lines.count
        }

        return (lines, diag)
    }

    // MARK: - character fallback

    private func extractViaCharacters(page: PDFPage, pageRect: CGRect) -> [Line] {
        let count = page.numberOfCharacters
        guard count > 0 else { return [] }
        let pageString = page.string ?? ""
        let scalars = Array(pageString.unicodeScalars)
        guard !scalars.isEmpty else { return [] }

        // Collect per-character info; skip degenerate-bounds glyphs.
        struct CharInfo { let scalar: UnicodeScalar; let bounds: CGRect }
        var chars: [CharInfo] = []
        chars.reserveCapacity(count)
        for i in 0..<count {
            guard i < scalars.count else { break }
            let bounds = page.characterBounds(at: i)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            chars.append(CharInfo(scalar: scalars[i], bounds: bounds))
        }
        guard !chars.isEmpty else { return [] }

        // Group into visual lines by clustering on y midpoint.
        let medianHeight = chars.map(\.bounds.height).sorted()[chars.count / 2]
        let yTolerance = max(medianHeight * 0.4, 0.5)

        // Sort by y descending (top first) for greedy grouping.
        let byY = chars.sorted { $0.bounds.midY > $1.bounds.midY }
        var lineGroups: [[CharInfo]] = []
        for ch in byY {
            if let lastIdx = lineGroups.indices.last,
               let ref = lineGroups[lastIdx].first,
               abs(ref.bounds.midY - ch.bounds.midY) <= yTolerance {
                lineGroups[lastIdx].append(ch)
            } else {
                lineGroups.append([ch])
            }
        }

        // Within each line: sort left to right and reconstruct text +
        // bounds. Insert a space when there's a horizontal gap larger
        // than ~1/3 of glyph height (heuristic for word boundary).
        var lines: [Line] = []
        for group in lineGroups {
            let sorted = group.sorted { $0.bounds.minX < $1.bounds.minX }
            var text = ""
            var bounds: CGRect = sorted[0].bounds
            var prevMaxX = sorted[0].bounds.minX
            for (j, info) in sorted.enumerated() {
                if j > 0, info.bounds.minX - prevMaxX > info.bounds.height * 0.3 {
                    text.append(" ")
                }
                text.append(Character(info.scalar))
                bounds = bounds.union(info.bounds)
                prevMaxX = info.bounds.maxX
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let normalized = normalize(bounds, in: pageRect) else { continue }
            lines.append(Line(text: trimmed, box: normalized))
        }
        return lines
    }

    // MARK: - normalization

    private func normalize(_ pageBounds: CGRect, in pageRect: CGRect) -> CGRect? {
        let nx = (pageBounds.minX - pageRect.minX) / pageRect.width
        let ny = (pageBounds.minY - pageRect.minY) / pageRect.height
        let nw = pageBounds.width / pageRect.width
        let nh = pageBounds.height / pageRect.height
        // Allow the normalized rect through even with tiny dimensions —
        // the gap-filler's vertical-overlap check uses min-height with
        // a guard for zero-height. We only reject NaN/inf here.
        guard nx.isFinite, ny.isFinite, nw.isFinite, nh.isFinite else { return nil }
        return CGRect(x: nx, y: ny, width: nw, height: nh)
    }
}
