import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import Layout
import OCR

/// Cloud Phase 5. Sonnet-driven table-structure extraction: crop the
/// page raster to a `.table` region, send the crop to Sonnet 4.6,
/// and parse the JSON response into `[[TableCell]]`. The model reads
/// each cell's text directly from the image — page OCR observations
/// aren't consulted — so this path also fixes the cases where Surya
/// table-rec produced cell bboxes but our per-page OCR misread
/// individual cell content.
///
/// Returns `nil` (so the caller can fall back to the Surya path) on:
///   * per-book budget exhausted,
///   * PNG encoding failure,
///   * network / API error,
///   * model refusal,
///   * JSON parse failure or shape mismatch,
///   * sub-`minRows` × `minCols` result (degenerate; the heuristic
///     uses the same floor).
///
/// One Sonnet call per `.table` region. Tables are rare per book
/// (~0.5/book in the cost-estimator model), so per-book cost stays
/// in the cents range even with this path enabled.
public struct ClaudeTableExtractor: TableExtractor {
    public let client: AnthropicAPIClient
    public let budget: ClaudeCallBudget
    public var model: AnthropicModel
    public var maxOutputTokens: Int

    public init(
        client: AnthropicAPIClient,
        budget: ClaudeCallBudget,
        model: AnthropicModel = .sonnet4_6,
        // Tables can carry a lot of cell text; budget output tokens
        // generously. A 10×6 academic table at ~30 chars/cell still
        // fits well under 4K, but multi-paragraph cells push higher.
        maxOutputTokens: Int = 4096
    ) {
        self.client = client
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    public func extract(
        pageImage: CGImage,
        regionBox: CGRect,
        observations: [TextObservation],
        stagingDir: URL,
        pageIndex: Int,
        regionIndex: Int
    ) async -> [[TableCell]]? {
        guard let cropped = RegionCascade.cropImage(pageImage, to: regionBox) else {
            return nil
        }
        guard await budget.tryConsume() else { return nil }
        try? Task.checkCancellation()

        guard let png = Self.encodePNG(cropped) else { return nil }
        let base64 = png.base64EncodedString()

        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: maxOutputTokens,
            system: .plain(Self.systemPrompt),
            messages: [
                Message(role: .user, content: .blocks([
                    .image(mediaType: .png, base64Data: base64),
                    .text(Self.userPrompt),
                ])),
            ],
            // Pure structural extraction — no chain-of-thought needed.
            // Disabling thinking saves tokens + latency; matches the
            // posture of every other Claude feature in the pipeline.
            thinking: .disabled
        )

        let response: AnthropicMessageResponse
        do {
            response = try await client.send(request)
        } catch {
            return nil
        }
        await budget.recordUsage(response.usage, for: model)

        if response.didRefuse { return nil }
        guard let raw = response.primaryText, !raw.isEmpty else { return nil }
        guard let rows = Self.parseRows(from: raw) else { return nil }

        // Same rows × cols floor as the heuristic and the Surya path.
        // Anything below this is most likely a misclassified region —
        // better to fall back than emit a degenerate `<table>`.
        let maxCols = rows.map(\.count).max() ?? 0
        guard rows.count >= TableHeuristic.minRows,
              maxCols >= TableHeuristic.minCols else {
            return nil
        }
        return rows
    }

    // MARK: - Prompt

    /// Stable system prompt — kept byte-stable across requests so the
    /// prefix is cacheable across the per-region calls in a book that
    /// happens to have several tables. The user turn carries no
    /// per-call hints today, but we keep the split so future per-call
    /// context (e.g. surrounding caption text) doesn't churn the
    /// system prompt.
    static let systemPrompt = """
        You are extracting a table from a book page. The image shows \
        ONE table region cropped from the page. Return the table as \
        compact JSON with exactly this shape — no preface, no \
        commentary, no markdown fences, no trailing prose:

        {"rows":[[{"text":"...","header":false,"rowspan":1,"colspan":1}, ...], ...]}

        Rules:
          * One row per visual row, top to bottom.
          * One cell per visual column, left to right. Empty cells \
        get "text":"".
          * "header":true for cells in header rows or header columns \
        (typically rendered in bold or above a horizontal rule). \
        Otherwise false.
          * "rowspan" and "colspan" are integers ≥ 1; omit or set to 1 \
        when the cell does NOT span. Span the SAME merged cell only \
        ONCE in the JSON — do not duplicate its text into each \
        spanned-over slot.
          * Transcribe cell text verbatim from the image. Preserve \
        diacritics, ligatures, and original punctuation. Do not \
        translate, modernize, or paraphrase. Use newlines for hard \
        line breaks within a cell.
          * If the image is not a table, or the structure is unclear, \
        return {"rows":[]}.
        """

    /// User-turn prompt; intentionally minimal so the system prefix
    /// stays cacheable.
    static let userPrompt = "Extract the table in this image."

    // MARK: - Parsing

    /// JSON shape the model is asked to return. Top-level
    /// `{"rows": [[Cell, ...], ...]}`. Cells carry `text` (always),
    /// optional `header` / `rowspan` / `colspan` (defaulting to
    /// false / 1 / 1). Strip code-fence wrappers before parsing —
    /// Sonnet occasionally wraps JSON output in ```json fences even
    /// when the prompt forbids it.
    static func parseRows(from raw: String) -> [[TableCell]]? {
        let cleaned = stripCodeFence(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let data = cleaned.data(using: .utf8) else {
            return nil
        }
        let decoded: WireGrid
        do {
            decoded = try JSONDecoder().decode(WireGrid.self, from: data)
        } catch {
            return nil
        }
        guard !decoded.rows.isEmpty else { return nil }

        let rows: [[TableCell]] = decoded.rows.map { wireRow in
            wireRow.map { wireCell in
                TableCell(
                    runs: wireCell.text.isEmpty ? [] : [InlineRun(wireCell.text)],
                    isHeader: wireCell.header ?? false,
                    rowspan: max(1, wireCell.rowspan ?? 1),
                    colspan: max(1, wireCell.colspan ?? 1)
                )
            }
        }
        return rows
    }

    /// Strip outer ```...``` fence (with optional language tag) from
    /// a model response. Conservative — only outer fence comes off,
    /// internal content is left alone.
    static func stripCodeFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else {
            return trimmed
        }
        var lines = trimmed.split(
            separator: "\n", omittingEmptySubsequences: false
        )
        if !lines.isEmpty { lines.removeFirst() }
        if !lines.isEmpty,
           lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private struct WireGrid: Decodable {
        let rows: [[WireCell]]
    }

    private struct WireCell: Decodable {
        let text: String
        let header: Bool?
        let rowspan: Int?
        let colspan: Int?
    }

    // MARK: - Helpers

    /// PNG encode a CGImage for inline base64 transmission. Same
    /// shape as `ClaudeOCREngine.encodePNG` and
    /// `ClaudePostProcessor.encodePNG`; duplicated rather than shared
    /// because the engines live in separate types and a dedicated
    /// helper namespace would be a single static method today.
    static func encodePNG(_ image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            UTType.png.identifier as CFString,
            1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }
}
