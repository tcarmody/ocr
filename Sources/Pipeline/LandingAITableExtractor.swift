import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AI
import Document
import OCR

/// LandingAI ADE table-structure extraction. Cropped `.table` region
/// goes to `/v1/ade/parse`; the response's markdown is parsed back
/// into `[[TableCell]]` via standard pipe-delimited table syntax.
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
///   * Markdown table syntax doesn't carry `rowspan` / `colspan`, so
///     merged cells flatten to 1×1. ADE's `grounding` payload has
///     spans but we don't currently decode it; future work if span
///     fidelity matters.
///   * Header detection is structural (cells above the `---|---`
///     separator row), not semantic — matches markdown convention.
public struct LandingAITableExtractor: TableExtractor {
    public let apiKeyProvider: @Sendable () -> String?
    public let budget: ClaudeCallBudget
    public var baseURL: URL
    public var model: String
    public var requestTimeout: TimeInterval

    public init(
        apiKeyProvider: @escaping @Sendable () -> String?,
        budget: ClaudeCallBudget,
        baseURL: URL = URL(string: "https://api.va.landing.ai")!,
        model: String = "dpt-2-latest",
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

        let boundary = "Boundary-" + UUID().uuidString
        var body = Data()
        body.append(Self.multipartTextField(
            name: "model", value: model, boundary: boundary
        ))
        body.append(Self.multipartFileField(
            name: "document",
            filename: "table.png",
            mimeType: "image/png",
            content: png,
            boundary: boundary
        ))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let url = baseURL.appendingPathComponent("/v1/ade/parse")
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body

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

        let envelope: ParseResponse
        do {
            envelope = try JSONDecoder().decode(ParseResponse.self, from: data)
        } catch {
            return nil
        }
        await budget.recordUsage(
            Usage(inputTokens: 0, outputTokens: 1),
            for: .landingAIDocumentExtraction
        )

        guard let markdown = envelope.markdown,
              !markdown.isEmpty,
              let rows = Self.parseMarkdownTable(markdown) else {
            return nil
        }

        // Same rows × cols floor as the heuristic and the other paths.
        let maxCols = rows.map(\.count).max() ?? 0
        guard rows.count >= TableHeuristic.minRows,
              maxCols >= TableHeuristic.minCols else {
            return nil
        }
        return rows
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

    // MARK: - Wire types

    private struct ParseResponse: Decodable {
        let markdown: String?
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

    private static func multipartTextField(
        name: String, value: String, boundary: String
    ) -> Data {
        var part = "--\(boundary)\r\n"
        part += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        part += "\(value)\r\n"
        return part.data(using: .utf8)!
    }

    private static func multipartFileField(
        name: String,
        filename: String,
        mimeType: String,
        content: Data,
        boundary: String
    ) -> Data {
        var part = Data()
        var header = "--\(boundary)\r\n"
        header += "Content-Disposition: form-data; name=\"\(name)\"; "
        header += "filename=\"\(filename)\"\r\n"
        header += "Content-Type: \(mimeType)\r\n\r\n"
        part.append(header.data(using: .utf8)!)
        part.append(content)
        part.append("\r\n".data(using: .utf8)!)
        return part
    }
}
