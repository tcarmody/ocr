import Foundation
import PDFKit
import AI
import Document
import EPUB

/// Pre-pipeline TOC parser. Looks for a printed table of contents
/// in the first ~20 pages of the PDF, sends the embedded text to
/// Haiku, and parses the structured response into a `ParsedTOC`
/// sidecar. The pipeline uses the result to override the heuristic
/// chapter titles `ChapterSplitter` would otherwise produce — so a
/// chapter that the splitter named "Chapter 3" gets retitled to
/// "The Theban Plays" if the TOC says so.
///
/// **Scope (v1).** Embedded-text only. PDFs without an embedded
/// text layer on the TOC pages skip this pass entirely (we'd need
/// to OCR those pages, which adds latency we don't want to pay at
/// queue-add time). Hierarchical TOCs are flattened — sub-section
/// entries land in the same flat list as top-level chapters.
/// Offset learning is naïve: try a small set of common offsets
/// and pick the one that matches the most TOC entries to actual
/// chapter starts.
public struct ClaudeTOCParser: Sendable {
    public let client: AnthropicAPIClient
    public let budget: CloudCallBudget
    public var model: AnthropicModel
    public var maxOutputTokens: Int

    public init(
        client: AnthropicAPIClient,
        budget: CloudCallBudget,
        model: AnthropicModel = .haiku4_5,
        maxOutputTokens: Int = 4096
    ) {
        self.client = client
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    /// Detect TOC pages, send them to Haiku, parse the response.
    /// Returns nil on any failure path (no embedded text on TOC
    /// pages, no detection, model refusal, malformed JSON, budget
    /// exhausted) — callers fall back to the heuristic chapter
    /// titles unchanged.
    public func parse(pdfURL: URL) async -> ParsedTOC? {
        guard let doc = PDFDocument(url: pdfURL), doc.pageCount > 0
        else { return nil }
        let tocPages = TOCPageDetector.detect(in: doc)
        guard !tocPages.isEmpty else { return nil }
        let joined = tocPages
            .compactMap { doc.page(at: $0)?.string }
            .joined(separator: "\n")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minSampleChars else { return nil }

        guard await budget.tryConsume() else { return nil }
        try? Task.checkCancellation()

        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: maxOutputTokens,
            // Cache the system prompt. Single call per book — the
            // win here is cross-book in a bulk run. 1h TTL covers
            // a session-long batch.
            system: .cached(Self.systemPrompt, ttl: .oneHour),
            messages: [
                Message(role: .user, content: .plain(trimmed)),
            ],
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
        return Self.parseResponse(raw)
    }

    /// Below this many characters across the detected TOC pages,
    /// don't waste a Haiku call. Real printed TOCs have hundreds
    /// of characters; very short text blocks are usually
    /// false-positive detections (cover pages with section
    /// headings).
    public static let minSampleChars: Int = 200

    /// Parse Haiku's JSON response into a `ParsedTOC`. The
    /// expected shape is `[{"title": "...", "displayPage": "..."}]`.
    /// Tolerates objects wrapped in code fences and trailing
    /// commentary by extracting the first balanced JSON array.
    static func parseResponse(_ raw: String) -> ParsedTOC? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip outer ```json ... ``` fences if present.
        let stripped: String
        if trimmed.hasPrefix("```") {
            var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            if !lines.isEmpty { lines.removeFirst() }
            if !lines.isEmpty,
               lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
                lines.removeLast()
            }
            stripped = lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            stripped = trimmed
        }
        // Pull the first balanced `[ ... ]` substring — Haiku
        // sometimes prefixes "Here is the parsed TOC:" before the
        // JSON despite the system-prompt instruction.
        guard let payload = Self.extractFirstArray(stripped) else { return nil }
        guard let data = payload.data(using: .utf8) else { return nil }
        struct DTO: Decodable {
            var title: String
            var displayPage: String
        }
        // Haiku may return `displayPage` as either a string or an
        // integer; tolerate both via a manual Decodable conformance.
        struct LooseDTO: Decodable {
            var title: String
            var displayPage: String
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.title = try c.decode(String.self, forKey: .title)
                if let str = try? c.decode(String.self, forKey: .displayPage) {
                    self.displayPage = str
                } else if let int = try? c.decode(Int.self, forKey: .displayPage) {
                    self.displayPage = String(int)
                } else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .displayPage, in: c,
                        debugDescription: "displayPage missing or wrong type"
                    )
                }
            }
            enum CodingKeys: String, CodingKey { case title, displayPage }
        }
        let decoded: [LooseDTO]
        do {
            decoded = try JSONDecoder().decode([LooseDTO].self, from: data)
        } catch {
            return nil
        }
        let entries = decoded
            .filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ParsedTOC.Entry(
                title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                displayPage: $0.displayPage
            ) }
        guard !entries.isEmpty else { return nil }
        return ParsedTOC(entries: entries)
    }

    /// Find the first balanced `[ ... ]` substring. Walks the
    /// string keeping a bracket depth counter; returns the first
    /// span starting at `[` that closes back at depth 0.
    static func extractFirstArray(_ s: String) -> String? {
        let chars = Array(s)
        guard let start = chars.firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        for i in start..<chars.count {
            let c = chars[i]
            if escape { escape = false; continue }
            if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = true; continue }
            if c == "[" { depth += 1 }
            else if c == "]" {
                depth -= 1
                if depth == 0 {
                    return String(chars[start...i])
                }
            }
        }
        return nil
    }

    static let systemPrompt = """
        You are extracting structured data from the printed table of \
        contents of a book. Return ONLY a valid JSON array — no \
        preface, no commentary, no code fences. Each array element \
        is an object with two string fields: `title` (the chapter or \
        section title as printed) and `displayPage` (the page number \
        printed next to it in the TOC, as a string — `"23"`, `"xviii"`, \
        `"1.4"`). Skip page-number leaders (dots / spaces). Skip \
        non-content entries like front-matter headings without page \
        numbers and recurring running heads from the TOC pages \
        themselves. Flatten any hierarchy — sub-sections belong in \
        the same array as top-level chapters, in their printed order.
        """
}

/// Heuristic for finding the printed TOC inside a PDF. Scans the
/// first ~20 pages of embedded text, scoring each by signals that
/// correlate with TOC-ness: an explicit "Contents" / "Table of
/// Contents" header, dot-leader patterns (`text....N`), and a high
/// density of trailing-page-number lines.
public enum TOCPageDetector {
    /// Pages 0…`maxScanPages - 1` are inspected. 20 pages covers
    /// almost every printed TOC; covers, copyright, dedication,
    /// preface, and TOC together rarely run past page 15.
    public static let maxScanPages = 20
    /// A page must score at least this to be classified as TOC.
    public static let minTOCPageScore = 3
    /// Number of `text...N` lines required for the dot-leader
    /// signal alone to qualify as a TOC page.
    public static let minLeaderLines = 5

    /// Returns the contiguous run of pages classified as TOC.
    /// Empty when no clear TOC was found. Conservative: when the
    /// detector finds isolated TOC-like pages (e.g. a single
    /// chapter listing on a back cover), returns empty rather
    /// than flagging them as a real TOC.
    public static func detect(in doc: PDFDocument) -> [Int] {
        let scan = min(maxScanPages, doc.pageCount)
        var perPageIsTOC: [Bool] = []
        for i in 0..<scan {
            guard let page = doc.page(at: i) else {
                perPageIsTOC.append(false); continue
            }
            let text = page.string ?? ""
            perPageIsTOC.append(scorePage(text) >= minTOCPageScore)
        }
        // Find the longest contiguous TOC run.
        var best: Range<Int>?
        var current: Range<Int>?
        for (i, isTOC) in perPageIsTOC.enumerated() {
            if isTOC {
                if let r = current {
                    current = r.lowerBound..<(i + 1)
                } else {
                    current = i..<(i + 1)
                }
            } else if let r = current {
                if best == nil || r.count > best!.count { best = r }
                current = nil
            }
        }
        if let r = current, best == nil || r.count > best!.count { best = r }
        guard let run = best, run.count >= 1 else { return [] }
        return Array(run)
    }

    /// Score a single page's text for TOC-ness. Returns the sum
    /// of independent signals — pages that hit ≥ `minTOCPageScore`
    /// are classified as TOC.
    static func scorePage(_ text: String) -> Int {
        var score = 0
        let lower = text.lowercased()
        // Explicit header. Worth 2 points — almost always
        // definitive when present.
        if lower.contains("table of contents") {
            score += 2
        } else if lower.contains("contents") {
            score += 1
        }
        // Dot-leader / page-number trailing pattern. Count how
        // many lines end with a run of dots / spaces followed by
        // a page number; ≥ minLeaderLines lines is worth 2,
        // anything between 2 and that is worth 1.
        let pattern = try! NSRegularExpression(
            pattern: #"[\.\s…]+\d{1,4}\s*$"#,
            options: [.anchorsMatchLines]
        )
        let nsText = text as NSString
        let matches = pattern.numberOfMatches(
            in: text, range: NSRange(location: 0, length: nsText.length)
        )
        // Dot-leader density is the strongest single signal — a
        // page with 5+ "text...N" lines is almost certainly a TOC,
        // even without an explicit header (some books typeset the
        // TOC without one). 3 points lets pure-leader pages clear
        // the threshold on their own.
        if matches >= minLeaderLines {
            score += 3
        } else if matches >= 2 {
            score += 1
        }
        return score
    }
}

/// Apply a `ParsedTOC` to a list of chapters: rename each chapter
/// whose first PDF page matches a TOC entry's display page (after
/// learning the offset between display and PDF pagination). Pure
/// function; runs after `ChapterSplitter` so the input chapters
/// already have their `pageAnchors` populated.
public enum TOCTitleApplier {
    /// Returns a copy of `chapters` with titles potentially
    /// replaced from `toc`. Also returns the offset that was
    /// inferred (or nil when no confident offset was found and the
    /// titles weren't touched).
    public static func apply(
        toc: ParsedTOC,
        chapters: [Chapter]
    ) -> (chapters: [Chapter], inferredOffset: Int?) {
        // Map each TOC entry's arabic display page (when parseable)
        // to its title. Roman-numeral / non-numeric entries are
        // dropped from offset learning since we can't compare them
        // to PDF page indices arithmetically.
        let arabicEntries = toc.entries.compactMap { entry -> (Int, String)? in
            guard let n = entry.displayPageInt, n > 0 else { return nil }
            return (n, entry.title)
        }
        guard !arabicEntries.isEmpty else { return (chapters, nil) }

        // Collect each chapter's first PDF page (lowest page anchor).
        let chapterStarts: [(idx: Int, pdf: Int)] = chapters.enumerated().compactMap { (i, ch) in
            guard let lowest = ch.pageAnchors.map(\.pdfPage).min() else { return nil }
            return (i, lowest)
        }
        guard !chapterStarts.isEmpty else { return (chapters, nil) }

        // Try a set of plausible offsets and pick the one that
        // matches the most (TOC entry, chapter start) pairs. The
        // offset is `pdfIndex = displayPage + offset - 1` (display
        // pages are 1-based, PDF indices 0-based, so offset 0
        // means "displayed page 1 == PDF index 0").
        let candidateOffsets = [0, 1, -1, 5, 10, 12, 15, 18, 20, 22, 25]
        var bestOffset: Int = 0
        var bestMatchCount = -1
        for offset in candidateOffsets {
            var matches = 0
            for (page, _) in arabicEntries {
                let inferredPDF = page + offset - 1
                if chapterStarts.contains(where: {
                    abs($0.pdf - inferredPDF) <= 1
                }) {
                    matches += 1
                }
            }
            if matches > bestMatchCount {
                bestMatchCount = matches
                bestOffset = offset
            }
        }
        // Require at least one match for the offset to be
        // considered "confident." Otherwise we don't override —
        // safer to keep the heuristic chapter titles than to apply
        // a TOC that doesn't align with the splitter's output.
        guard bestMatchCount > 0 else { return (chapters, nil) }

        // Apply titles. For each chapter, find the TOC entry
        // whose computed PDF page matches (within ±1).
        var updated = chapters
        for entry in toc.entries {
            guard let displayInt = entry.displayPageInt else { continue }
            let inferredPDF = displayInt + bestOffset - 1
            for i in updated.indices {
                let pdfStart = updated[i].pageAnchors.map(\.pdfPage).min()
                if let p = pdfStart, abs(p - inferredPDF) <= 1 {
                    updated[i].title = entry.title
                    break
                }
            }
        }
        return (updated, bestOffset)
    }
}
