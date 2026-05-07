import Foundation
import AI
import Document

/// Tier 9 / Q-Metadata. One Haiku call per book that reads the
/// first ~5 pages of OCR'd text and extracts standard publication
/// metadata: title, author, year, publisher, ISBN. The result
/// updates the `Book`'s OPF metadata, so EPUB readers + the
/// Library window get real titles and dates instead of source-
/// filename fallbacks.
///
/// Cost: ~one Haiku call per book at < $0.001. Effectively free.
/// Returns nil whenever Haiku declines, the response doesn't
/// parse, or the budget is exhausted — caller falls back to
/// existing values (the user-provided title or filename
/// derivation).
public struct ClaudeMetadataExtractor: Sendable {
    public let client: AnthropicAPIClient
    public let budget: ClaudeCallBudget
    public var model: AnthropicModel
    public var maxOutputTokens: Int

    public init(
        client: AnthropicAPIClient,
        budget: ClaudeCallBudget,
        model: AnthropicModel = .haiku4_5,
        maxOutputTokens: Int = 512  // ample for the JSON shape
    ) {
        self.client = client
        self.budget = budget
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    /// Extracted metadata. Every field is optional — Haiku reports
    /// only what it can read off the front matter. Empty strings
    /// don't get returned (caller treats nil + empty interchangeably).
    public struct Result: Sendable, Equatable {
        public let title: String?
        public let author: String?
        public let year: String?
        public let publisher: String?
        /// Raw digit string (hyphens stripped). 10 or 13 digits.
        public let isbn: String?

        public init(
            title: String? = nil,
            author: String? = nil,
            year: String? = nil,
            publisher: String? = nil,
            isbn: String? = nil
        ) {
            self.title = title
            self.author = author
            self.year = year
            self.publisher = publisher
            self.isbn = isbn
        }

        public var isEmpty: Bool {
            title == nil && author == nil && year == nil
                && publisher == nil && isbn == nil
        }
    }

    /// Run extraction over `frontMatterText`. Returns nil on
    /// budget exhaustion / refusal / parse failure / empty result.
    public func extract(frontMatterText: String) async -> Result? {
        let trimmed = frontMatterText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Don't call Haiku on a stub — too little signal to extract
        // anything reliable, and we'd just burn a call.
        guard trimmed.count >= 80 else { return nil }
        guard await budget.tryConsume() else { return nil }
        try? Task.checkCancellation()

        let request = AnthropicMessageRequest(
            model: model,
            maxTokens: maxOutputTokens,
            // Cache the system prompt — runs once per book but
            // bulk runs hit the same prompt across books in a
            // session. 1h TTL covers session-long batches.
            system: .cached(Self.systemPrompt, ttl: .oneHour),
            messages: [
                Message(role: .user, content: .plain(trimmed)),
            ],
            // No reasoning — pure extraction from visible text.
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
        return Self.parse(raw)
    }

    /// Sample the first ~`maxChars` characters of body text out
    /// of `chapters`, walking only headings + paragraphs (skipping
    /// figures / tables / anchors). The front-matter chapter
    /// (when present) usually carries the title page + copyright
    /// page; if that's not enough, spill into the first body
    /// chapter for the author / year / ISBN we missed.
    public static func sampleFrontMatter(
        from chapters: [Chapter], maxChars: Int = 4000
    ) -> String {
        // Hard chapter cap, independent of the char budget. Front
        // matter + first body chapter is plenty; deeper into the
        // book the extractor would just see body text and might
        // mis-identify a sentence opening as a title.
        let chapterCap = 2
        var collected = ""
        for chapter in chapters.prefix(chapterCap) {
            // Title row marker — gives Haiku a hint that the
            // chapter title might itself be the book title for
            // single-chapter front matter.
            if let title = chapter.title, !title.isEmpty {
                collected += "[Section: \(title)]\n"
            }
            for block in chapter.blocks {
                let text: String
                switch block {
                case .heading(_, let runs), .paragraph(let runs):
                    text = runs.map(\.text).joined()
                case .figure(_, _, let caption):
                    text = caption.map(\.text).joined()
                case .anchor, .table:
                    continue
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if !collected.isEmpty { collected += "\n" }
                collected += trimmed
                if collected.count >= maxChars {
                    return String(collected.prefix(maxChars))
                }
            }
        }
        return collected
    }

    // MARK: - parsing

    /// Decode Haiku's JSON response into a `Result`. Empty strings
    /// are normalized to nil; ISBN gets hyphens / spaces stripped.
    static func parse(_ raw: String) -> Result? {
        let cleaned = stripCodeFence(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let data = cleaned.data(using: .utf8) else {
            return nil
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            return nil
        }
        let result = Result(
            title: nilIfEmpty(wire.title),
            author: nilIfEmpty(wire.author),
            year: normalizeYear(wire.year),
            publisher: nilIfEmpty(wire.publisher),
            isbn: normalizeISBN(wire.isbn)
        )
        return result.isEmpty ? nil : result
    }

    private struct Wire: Decodable {
        let title: String?
        let author: String?
        let year: String?
        let publisher: String?
        let isbn: String?
    }

    static func nilIfEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Year normalization: extract a 4-digit substring if present.
    /// Haiku sometimes returns "2003" and sometimes "© 2003" or
    /// "first published 2003". We want the 4 digits.
    static func normalizeYear(_ s: String?) -> String? {
        guard let raw = nilIfEmpty(s) else { return nil }
        let regex = try? NSRegularExpression(pattern: #"\b(\d{4})\b"#)
        let range = NSRange(raw.startIndex..., in: raw)
        if let match = regex?.firstMatch(in: raw, range: range),
           match.numberOfRanges >= 2,
           let r = Range(match.range(at: 1), in: raw) {
            return String(raw[r])
        }
        return nil
    }

    /// ISBN normalization: strip hyphens / spaces, validate that
    /// what's left is 10 or 13 digits (or 9 + X for ISBN-10).
    /// Returns the stripped form on success, nil on malformed.
    static func normalizeISBN(_ s: String?) -> String? {
        guard let raw = nilIfEmpty(s) else { return nil }
        let stripped = raw
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard stripped.count == 10 || stripped.count == 13 else { return nil }
        for (i, ch) in stripped.enumerated() {
            if ch.isNumber { continue }
            // ISBN-10's last char can be 'X' (capital).
            if i == stripped.count - 1, stripped.count == 10,
               (ch == "X" || ch == "x") { continue }
            return nil
        }
        return stripped.uppercased()
    }

    /// Strip outer ```...``` code-fence wrapper if present.
    /// Haiku occasionally wraps JSON in fences even when the
    /// prompt asks for bare JSON.
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

    // MARK: - prompt

    /// System prompt — byte-stable across calls so the cache
    /// prefix hits across books in a session. Constrains output
    /// to the closed JSON shape the parser expects, with explicit
    /// guidance to leave fields null when not visible.
    static let systemPrompt = """
        You extract publication metadata from the front matter of \
        a book (title page, copyright page, half-title). The user \
        message contains OCR'd text from the first few pages.

        Return ONE JSON object with EXACTLY these keys: \
        "title", "author", "year", "publisher", "isbn". For each \
        key, return the value as it appears in the text (verbatim) \
        or null if it isn't visible. DO NOT guess. DO NOT \
        synthesize from related fields. DO NOT include other keys.

        Conventions:
          * "title": the main book title only — exclude subtitles \
        and series names unless they're typographically inseparable.
          * "author": single name or "FirstName LastName, OtherName \
        OtherLastName" for multiple authors. Editors / translators \
        excluded.
          * "year": four-digit publication year as a string ("2003"). \
        Pick the original publication year when both reprint and \
        original are visible.
          * "publisher": publisher name only — exclude city, \
        imprint, etc.
          * "isbn": ISBN-10 or ISBN-13 as printed (hyphens OK; we \
        strip them downstream).

        Return ONLY the JSON object — no preface, no commentary, \
        no markdown fences.
        """
}
