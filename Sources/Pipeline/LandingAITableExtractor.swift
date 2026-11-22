import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import OCR

/// LandingAI ADE table-structure extraction. Cropped `.table` region
/// goes to the Gen2 parse API (`POST /v2/parse`, DPT-3 Pro — see
/// `LandingAIParse`). The first `table` block in the response's
/// `structure` tree becomes `[[TableCell]]` straight from its
/// `table_cell` nodes, merged cells kept as `rowspan` / `colspan`.
/// Fallbacks, in order: the first HTML `<table>` in the flat markdown
/// (also span-aware), then a pipe-syntax table.
///
/// When wired ahead of `ClaudeTableExtractor` (Cloud-mode setting
/// `landingAITableExtraction`), this becomes the first cloud attempt
/// for each table region — ADE is purpose-built for layout and table
/// understanding, and on dense academic tables it often beats the
/// Claude prompt-based approach for cell-boundary detection. Falls
/// back to Claude (then Surya) when ADE returns no parseable table
/// or sub-2×2 dimensions.
///
/// Limitations vs `ClaudeTableExtractor`:
///   * Gen2 has no header flag. The rows covered by the first row's
///     cells are marked as header (`<th>` cells win in the HTML
///     fallback; cells above `---|---` in the pipe fallback) — a
///     structural guess, not semantic detection.
///   * Only the first table in the crop is returned.
public struct LandingAITableExtractor: TableExtractor {
    public let apiKeyProvider: @Sendable () -> String?
    public let budget: CloudCallBudget
    public var baseURL: URL
    public var model: String
    public var requestTimeout: TimeInterval

    public init(
        apiKeyProvider: @escaping @Sendable () -> String?,
        budget: CloudCallBudget,
        baseURL: URL = LandingAIParse.defaultBaseURL,
        model: String = LandingAIParse.defaultModel,
        requestTimeout: TimeInterval = 120
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.budget = budget
        self.baseURL = baseURL
        self.model = model
        self.requestTimeout = requestTimeout
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

        guard let key = apiKeyProvider(), !key.isEmpty else { return nil }
        guard let png = Self.encodePNG(cropped) else { return nil }

        let request = LandingAIParse.makeRequest(
            baseURL: baseURL, apiKey: key, model: model,
            png: png, filename: "table.png", timeout: requestTimeout
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return nil
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }

        let envelope: LandingAIParse.Response
        do {
            envelope = try LandingAIParse.decode(data)
        } catch {
            return nil
        }
        await budget.recordUsage(
            LandingAIParse.usage(for: envelope),
            for: .landingAIDPT3Pro
        )

        guard let rows = Self.rows(from: envelope) else { return nil }

        // Same rows × cols floor as the heuristic and the other paths.
        let maxCols = LandingAIParse.columnCount(rows)
        guard rows.count >= TableHeuristic.minRows,
              maxCols >= TableHeuristic.minCols else {
            return nil
        }
        return rows
    }

    /// Rows for the first table in `response`: structure tree, then
    /// HTML `<table>` in the markdown, then pipe syntax. Nil when none
    /// yields a table.
    static func rows(from response: LandingAIParse.Response) -> [[TableCell]]? {
        if let table = response.blocks.first(where: { $0.type == "table" }) {
            let rows = LandingAIParse.tableRows(from: table, in: response)
            if !rows.isEmpty { return rows }
        }
        let markdown = LandingAIParse.cleanMarkdown(response.markdown ?? "")
        guard !markdown.isEmpty else { return nil }
        if let rows = LandingAIParse.parseHTMLTable(markdown), !rows.isEmpty {
            return rows
        }
        return parseMarkdownTable(markdown)
    }

    // MARK: - Markdown table parsing

    /// Parse the first pipe-delimited markdown table out of `raw`.
    /// Returns nil if no table-shaped block is present. Recognizes the
    /// standard GitHub-flavored table:
    ///
    ///     | header1 | header2 |
    ///     |---------|---------|
    ///     | cell    | cell    |
    ///
    /// The separator row (`---|---`) marks the header boundary; cells
    /// in any row before it get `isHeader: true`. When no separator
    /// row is present (some ADE outputs omit it for headerless tables)
    /// no row is treated as header — caller still gets the cells.
    static func parseMarkdownTable(_ raw: String) -> [[TableCell]]? {
        // Scan for the first contiguous run of pipe-prefixed lines.
        // ADE sometimes precedes the table with a caption paragraph;
        // we skip non-table lines until we hit the table block.
        let lines = raw.split(
            separator: "\n", omittingEmptySubsequences: false
        ).map { String($0).trimmingCharacters(in: .whitespaces) }

        var tableLines: [String] = []
        var separatorIndex: Int? = nil
        for line in lines {
            if line.hasPrefix("|") {
                if isSeparatorRow(line) {
                    separatorIndex = tableLines.count
                }
                tableLines.append(line)
            } else if !tableLines.isEmpty {
                // Table block ended; stop scanning so a second table
                // further down doesn't get merged into the first.
                break
            }
        }
        guard !tableLines.isEmpty else { return nil }

        var rows: [[TableCell]] = []
        for (i, line) in tableLines.enumerated() {
            if i == separatorIndex { continue }
            let cells = splitCells(line)
            guard !cells.isEmpty else { continue }
            let isHeader: Bool
            if let sep = separatorIndex {
                isHeader = i < sep
            } else {
                isHeader = false
            }
            rows.append(cells.map { text in
                TableCell(
                    runs: text.isEmpty ? [] : [InlineRun(text)],
                    isHeader: isHeader,
                    rowspan: 1,
                    colspan: 1
                )
            })
        }
        return rows.isEmpty ? nil : rows
    }

    /// True for the GitHub-flavored separator row, e.g. `|---|:---:|`.
    /// Tolerates whitespace, alignment colons, and any number of dashes.
    static func isSeparatorRow(_ line: String) -> Bool {
        let cells = splitCells(line)
        guard !cells.isEmpty else { return false }
        let dashChars: Set<Character> = ["-", ":"]
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty
                && trimmed.allSatisfy { dashChars.contains($0) }
        }
    }

    /// Split one `|`-delimited row into its cell texts. Strips the
    /// leading and trailing pipes if present (markdown tables can be
    /// written with or without outer pipes).
    static func splitCells(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Helpers

    private static func encodePNG(_ image: CGImage) -> Data? {
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
