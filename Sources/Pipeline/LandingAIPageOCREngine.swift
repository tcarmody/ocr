import Foundation
import CoreGraphics
import Document
import OCR

/// `PageOCREngine` impl backed by LandingAI ADE (`/v1/ade/parse`). Same
/// `ClaudePageResult` output contract as `ClaudePageOCREngine` and
/// `GeminiPageOCREngine`; the cascade-bypass page-OCR loop is unified
/// across providers.
///
/// **Why this exists**: ADE is purpose-built for "agentic document
/// extraction" — its segmentation on dense diagram-heavy layouts
/// (technical reports, multi-figure scientific papers, tables-and-
/// figures interleaved with prose) beats the LLM-prompt path's
/// best efforts at parsing free-form vision output. The returned
/// markdown carries inline MathML for math regions and pipe-table
/// markdown for tables, both of which round-trip through the page-
/// OCR parser into `Block.figure` / `Block.table` / inline math
/// `rawXHTML` without losing structure.
///
/// **Cost**: most expensive whole-page option (~$0.03/page, ~6× Gemini
/// Flash, ~30% pricier than Sonnet). No batch API, no prompt caching,
/// no streaming — single sync call per page. Worth it for diagram-
/// heavy corpora; over-budget for routine prose. Per-book budget
/// (`CloudCallBudget`) gates total spend regardless.
///
/// **Limitations**: manuscript mode hard-pins Claude — ADE doesn't
/// handle handwriting. Figures still come from Surya layout +
/// FigureExtractor (the page-OCR shortcut path's normal flow);
/// ADE's markdown reference to figures gets translated to caption
/// text only.
public struct LandingAIPageOCREngine: PageOCREngine, Sendable {
    public var providerId: String { "landingai-" + (document.model) }

    public let document: LandingAIDocumentEngine

    public init(document: LandingAIDocumentEngine) {
        self.document = document
    }

    public func recognize(
        pageImage: CGImage,
        pageIndex: Int,
        languages: [BCP47]
    ) async throws -> ClaudePageResult {
        let result = try await document.recognize(
            image: pageImage,
            hints: OCRHints(languages: languages)
        )
        // Empty response → empty result; pipeline records it as
        // `.empty` provider status. The Vision back-fill fallback
        // still runs upstream when this is the only signal.
        let blocks = Self.parseMarkdown(result.text)
        return ClaudePageResult(blocks: blocks, footnotes: [])
    }

    public func classify(error: any Error) -> ProviderStatus {
        if error is CancellationError { return .canceled }
        if let docErr = error as? LandingAIDocumentEngine.DocumentOCRError {
            switch docErr {
            case .budgetExhausted: return .budgetExhausted
            case .emptyResponse:   return .empty
            case .http(let status, _):
                return status == 429 ? .rateLimited : .apiError
            case .missingAPIKey, .pngEncodeFailed,
                 .decode, .underlying:
                return .apiError
            }
        }
        return .apiError
    }

    // MARK: - Markdown → [Block]

    /// Minimal markdown converter for ADE's response shape. Handles
    /// the constructs ADE actually emits:
    ///   * ATX headings (`#`, `##`, `###`)
    ///   * Paragraphs (blank-line separated)
    ///   * Pipe tables (header row + `|---|---|` separator + body)
    ///   * Inline `**bold**` / `*italic*`
    ///   * Inline `<math>…</math>` HTML — passed through verbatim
    ///     as `InlineRun.rawXHTML` so the page-XHTML writer emits
    ///     it as MathML without escaping
    ///   * Markdown images `![alt](url)` — dropped (figures come
    ///     from Surya layout + FigureExtractor on the same page)
    ///
    /// Not CommonMark-complete — covers the subset ADE returns plus
    /// inline HTML pass-through for math.
    static func parseMarkdown(_ text: String) -> [Block] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: " ")
            let runs = parseInline(joined)
            if !runs.isEmpty { blocks.append(.paragraph(runs: runs)) }
            paragraph.removeAll(keepingCapacity: true)
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                i += 1
                continue
            }
            if let h = parseHeading(line) {
                flushParagraph()
                let runs = parseInline(h.text)
                if !runs.isEmpty {
                    blocks.append(.heading(level: h.level, runs: runs))
                }
                i += 1
                continue
            }
            // Pipe table detection: current line starts with `|` and
            // the next non-empty line is the separator row
            // (`|---|---|`). Consume header + separator + body until
            // a non-pipe line. Anything that doesn't match the
            // separator shape falls through to the paragraph path —
            // a stray `|character|` in body text shouldn't trigger
            // false table parsing.
            if line.hasPrefix("|"),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let (table, consumed) = parsePipeTable(
                    lines: lines, startIndex: i
                )
                if let table {
                    blocks.append(table)
                    i += consumed
                    continue
                }
            }
            paragraph.append(raw)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    /// ATX heading `# text` / `## text` / `### text` etc. Returns
    /// `nil` for non-heading lines.
    static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level >= 1, idx < line.endIndex, line[idx] == " " else {
            return nil
        }
        let text = String(line[line.index(after: idx)...])
            .trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    /// Pipe-table separator row: `|---|---|---|` (with optional
    /// alignment colons we ignore). Conservative — any cell must
    /// be at least one `-`.
    static func isTableSeparator(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("|"), line.hasSuffix("|") else { return false }
        let inner = line.dropFirst().dropLast()
        let cells = inner.split(separator: "|", omittingEmptySubsequences: false)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            let t = cell.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ":", with: "")
            guard !t.isEmpty, t.allSatisfy({ $0 == "-" }) else {
                return false
            }
        }
        return true
    }

    /// Parse a pipe table starting at `startIndex` (header row).
    /// Returns the `Block.table` plus the number of lines consumed
    /// (header + separator + body rows). Returns `nil` when the
    /// shape doesn't actually parse — caller falls through to the
    /// paragraph path.
    static func parsePipeTable(
        lines: [String], startIndex: Int
    ) -> (Block?, Int) {
        guard startIndex + 1 < lines.count else { return (nil, 0) }
        let headerCells = splitPipeCells(lines[startIndex])
        guard !headerCells.isEmpty else { return (nil, 0) }
        var rows: [[TableCell]] = [
            headerCells.map { cell in
                TableCell(
                    runs: parseInline(cell),
                    isHeader: true, rowspan: 1, colspan: 1
                )
            }
        ]
        var consumed = 2 // header + separator
        var row = startIndex + 2
        while row < lines.count {
            let line = lines[row].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || !line.hasPrefix("|") { break }
            let cells = splitPipeCells(lines[row])
            if cells.isEmpty { break }
            rows.append(cells.map { cell in
                TableCell(
                    runs: parseInline(cell),
                    isHeader: false, rowspan: 1, colspan: 1
                )
            })
            row += 1
            consumed += 1
        }
        guard rows.count >= 2 else { return (nil, 0) }
        return (.table(rows: rows, caption: []), consumed)
    }

    /// Split `| a | b | c |` into `["a", "b", "c"]`. Trims each
    /// cell; preserves empty cells (so `| a || b |` keeps the
    /// middle empty cell). Returns `[]` on a line that doesn't
    /// open with `|`.
    static func splitPipeCells(_ raw: String) -> [String] {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("|"), line.hasSuffix("|") else { return [] }
        let inner = line.dropFirst().dropLast()
        return inner
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Inline runs

    /// Convert one paragraph of markdown into `[InlineRun]`. Handles:
    ///   * `<math …>…</math>` HTML pass-through — entire subtree
    ///     emitted as a single `InlineRun.rawXHTML`. Text before
    ///     and after the math element is parsed independently.
    ///   * `**bold**` / `*italic*` inline emphasis.
    ///   * `![alt](url)` images — stripped (caller drops them).
    ///   * Plain text otherwise.
    static func parseInline(_ text: String) -> [InlineRun] {
        var out: [InlineRun] = []
        var rest = text[...]
        while let mathRange = rest.range(of: "<math") {
            let prefix = String(rest[rest.startIndex..<mathRange.lowerBound])
            if !prefix.isEmpty {
                out.append(contentsOf: parseEmphasis(prefix))
            }
            // Find the matching </math>; if not present, treat the
            // open tag as literal text and bail out.
            guard let closeRange = rest.range(
                of: "</math>", range: mathRange.lowerBound..<rest.endIndex
            ) else {
                out.append(contentsOf: parseEmphasis(String(rest)))
                return out
            }
            let mathML = String(
                rest[mathRange.lowerBound..<closeRange.upperBound]
            )
            // Plain-text fallback for sibling .txt / .md outputs:
            // strip MathML tags down to the bare characters they
            // contain. Imperfect but cheap; the EPUB renders the
            // real markup from `rawXHTML`.
            let fallback = mathML
                .replacingOccurrences(
                    of: "<[^>]+>", with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespaces)
            out.append(InlineRun(
                fallback.isEmpty ? "[math]" : fallback,
                rawXHTML: mathML
            ))
            rest = rest[closeRange.upperBound...]
        }
        if !rest.isEmpty {
            out.append(contentsOf: parseEmphasis(String(rest)))
        }
        return out
    }

    /// Strip markdown image syntax `![alt](url)` (figures come from
    /// Surya, not ADE), then parse `**bold**` and `*italic*` emphasis.
    /// Doesn't handle nested or escaped emphasis — same posture as
    /// `DocumentIngest.parseMarkdown`'s inline pass.
    static func parseEmphasis(_ text: String) -> [InlineRun] {
        // Drop image syntax — non-greedy match to handle multiple
        // images on a line.
        let stripped = text.replacingOccurrences(
            of: #"!\[[^\]]*\]\([^\)]*\)"#,
            with: "", options: .regularExpression
        )
        guard !stripped.isEmpty else { return [] }
        var out: [InlineRun] = []
        var i = stripped.startIndex
        var buffer = ""

        func flushBuffer(italic: Bool = false, bold: Bool = false) {
            if !buffer.isEmpty {
                out.append(InlineRun(
                    buffer, isItalic: italic, isBold: bold
                ))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        while i < stripped.endIndex {
            // `**bold**`
            if stripped.distance(from: i, to: stripped.endIndex) >= 4,
               stripped[i] == "*",
               stripped[stripped.index(after: i)] == "*" {
                let start = stripped.index(i, offsetBy: 2)
                if let close = stripped.range(
                    of: "**", range: start..<stripped.endIndex
                ) {
                    flushBuffer()
                    let inner = String(stripped[start..<close.lowerBound])
                    if !inner.isEmpty {
                        out.append(InlineRun(inner, isBold: true))
                    }
                    i = close.upperBound
                    continue
                }
            }
            // `*italic*`
            if stripped[i] == "*" {
                let start = stripped.index(after: i)
                if let close = stripped.range(
                    of: "*", range: start..<stripped.endIndex
                ) {
                    flushBuffer()
                    let inner = String(stripped[start..<close.lowerBound])
                    if !inner.isEmpty {
                        out.append(InlineRun(inner, isItalic: true))
                    }
                    i = close.upperBound
                    continue
                }
            }
            buffer.append(stripped[i])
            i = stripped.index(after: i)
        }
        flushBuffer()
        // Single plain-text run is the common case; collapse to it.
        if out.isEmpty, !buffer.isEmpty {
            return [InlineRun(buffer)]
        }
        return out
    }
}
