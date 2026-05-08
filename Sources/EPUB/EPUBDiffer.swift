import Foundation

/// Compare two EPUBs at the chapter / paragraph level. Produces a
/// structured `EPUBDiff` that callers can render however they like
/// (a plain-text unified-diff report, a side-by-side view, etc.).
///
/// Chapters are paired by spine position — the typical use case is
/// "I converted this book twice with different settings, what
/// changed?" where both EPUBs share the same source PDF + chapter
/// boundaries. Mismatched spine lengths are tolerated: extra
/// chapters in either side appear as fully-added or fully-removed.
public struct EPUBDiffer {

    public init() {}

    public enum DiffError: Error, LocalizedError {
        case openFailed(URL, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let url, let err):
                return "Couldn't open \(url.lastPathComponent): \(err.localizedDescription)"
            }
        }
    }

    /// Run the diff. Both EPUBs are loaded into memory; the working
    /// directories clean up automatically when the books deinit.
    public func diff(leftURL: URL, rightURL: URL) throws -> EPUBDiff {
        let left: EPUBBook
        let right: EPUBBook
        do {
            left = try EPUBBook.open(epubURL: leftURL)
        } catch {
            throw DiffError.openFailed(leftURL, underlying: error)
        }
        do {
            right = try EPUBBook.open(epubURL: rightURL)
        } catch {
            throw DiffError.openFailed(rightURL, underlying: error)
        }

        let leftChapters = left.spine.compactMap { left.resourcesByID[$0] }
        let rightChapters = right.spine.compactMap { right.resourcesByID[$0] }

        let chapterCount = max(leftChapters.count, rightChapters.count)
        var chapterDiffs: [ChapterDiff] = []
        for i in 0..<chapterCount {
            let leftChapter = i < leftChapters.count ? leftChapters[i] : nil
            let rightChapter = i < rightChapters.count ? rightChapters[i] : nil
            chapterDiffs.append(diffChapter(
                index: i, left: leftChapter, right: rightChapter
            ))
        }

        return EPUBDiff(
            leftURL: leftURL,
            rightURL: rightURL,
            leftTitle: left.metadata.title ?? leftURL.lastPathComponent,
            rightTitle: right.metadata.title ?? rightURL.lastPathComponent,
            chapterDiffs: chapterDiffs
        )
    }

    private func diffChapter(
        index: Int, left: Resource?, right: Resource?
    ) -> ChapterDiff {
        let leftTitle = left.flatMap { Self.headingTitle(in: $0.text ?? "") }
            ?? "Chapter \(index + 1)"
        let rightTitle = right.flatMap { Self.headingTitle(in: $0.text ?? "") }
            ?? "Chapter \(index + 1)"

        let leftParas = left.map { Self.paragraphs(in: $0.text ?? "") } ?? []
        let rightParas = right.map { Self.paragraphs(in: $0.text ?? "") } ?? []

        // CollectionDifference returns insertions + removals;
        // the insertion offsets are in the new collection's coordinate
        // space and removals in the old collection's. We render them
        // by walking both and emitting unchanged / removed / added in
        // a single stream so the output reads top-to-bottom.
        let changes = unifiedChanges(from: leftParas, to: rightParas)

        return ChapterDiff(
            index: index,
            leftTitle: leftTitle,
            rightTitle: rightTitle,
            isLeftMissing: left == nil,
            isRightMissing: right == nil,
            changes: changes
        )
    }

    /// Produce a sequential list of changes that read like a unified
    /// diff: walk through both arrays, emit unchanged paragraphs as
    /// `.unchanged`, and around the edits emit `.removed` for things
    /// only in left and `.added` for things only in right.
    ///
    /// Uses `CollectionDifference` to compute the LCS-derived
    /// add/remove operations, then interleaves them back into reading
    /// order.
    private func unifiedChanges(
        from left: [String], to right: [String]
    ) -> [ParagraphChange] {
        let difference = right.difference(from: left)

        // Index removals + insertions by offset in their respective
        // sources so we can interleave them as we walk.
        var removalsByOldOffset: [Int: String] = [:]
        var insertionsByNewOffset: [Int: String] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, let element, _):
                removalsByOldOffset[offset] = element
            case .insert(let offset, let element, _):
                insertionsByNewOffset[offset] = element
            }
        }

        var result: [ParagraphChange] = []
        var leftIdx = 0
        var rightIdx = 0
        while leftIdx < left.count || rightIdx < right.count {
            // Removals are keyed by their offset in the old (left)
            // collection; insertions by their offset in the new
            // (right). Process them in document order: emit a
            // removal when leftIdx hits its key, an insertion when
            // rightIdx hits its key, otherwise advance both as
            // unchanged.
            if leftIdx < left.count, let removed = removalsByOldOffset[leftIdx] {
                result.append(.removed(removed))
                leftIdx += 1
            } else if rightIdx < right.count, let inserted = insertionsByNewOffset[rightIdx] {
                result.append(.added(inserted))
                rightIdx += 1
            } else if leftIdx < left.count, rightIdx < right.count,
                      left[leftIdx] == right[rightIdx] {
                result.append(.unchanged(left[leftIdx]))
                leftIdx += 1
                rightIdx += 1
            } else {
                // Defensive — shouldn't reach here if removals +
                // insertions cover all the differences. Break to
                // avoid infinite loop in case of bug.
                break
            }
        }
        return result
    }

    // MARK: - Text extraction

    /// Pull paragraph text from chapter XHTML. Matches `<p>...</p>`
    /// (single quotes, attributes, etc.), strips inner tags, trims
    /// whitespace. Lazy regex so nested or weird markup doesn't
    /// over-match.
    static func paragraphs(in xhtml: String) -> [String] {
        guard let regex = paragraphRegex else { return [] }
        let nsText = xhtml as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: xhtml, range: fullRange)
        return matches.compactMap { match -> String? in
            guard match.numberOfRanges >= 2,
                  let inner = Range(match.range(at: 1), in: xhtml)
            else { return nil }
            let raw = String(xhtml[inner])
            return Self.normalize(raw)
        }.filter { !$0.isEmpty }
    }

    /// Strip inline tags, decode common entities, collapse runs of
    /// whitespace, trim. The result is what readers see — surface
    /// form is invariant to markup-level tweaks.
    static func normalize(_ s: String) -> String {
        var stripped = s.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        )
        stripped = stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        stripped = stripped.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract the first heading's text from a chapter — mirrors
    /// `PackageEditor.firstHeadingTitle(in:)` but with normalized
    /// output. Inlined here to keep the differ standalone.
    static func headingTitle(in xhtml: String) -> String? {
        for tag in ["h1", "h2", "h3"] {
            let pattern = "<\(tag)[^>]*>([\\s\\S]*?)</\(tag)>"
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ),
            let match = regex.firstMatch(
                in: xhtml,
                range: NSRange(xhtml.startIndex..., in: xhtml)
            ),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: xhtml)
            else { continue }
            let title = normalize(String(xhtml[range]))
            if !title.isEmpty { return title }
        }
        return nil
    }

    private static let paragraphRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"<p\b[^>]*>([\s\S]*?)</p>"#,
        options: [.caseInsensitive]
    )
}

// MARK: - Result types

public struct EPUBDiff: Equatable, Sendable {
    public let leftURL: URL
    public let rightURL: URL
    public let leftTitle: String
    public let rightTitle: String
    public let chapterDiffs: [ChapterDiff]

    /// Total count of paragraphs that differ across all chapters.
    public var totalChanges: Int {
        chapterDiffs.reduce(0) { $0 + $1.changedCount }
    }

    /// Chapters with at least one paragraph change.
    public var chaptersWithChanges: Int {
        chapterDiffs.filter { $0.hasChanges }.count
    }
}

public struct ChapterDiff: Equatable, Sendable {
    public let index: Int
    public let leftTitle: String
    public let rightTitle: String
    public let isLeftMissing: Bool
    public let isRightMissing: Bool
    public let changes: [ParagraphChange]

    public var changedCount: Int {
        changes.filter { !$0.isUnchanged }.count
    }

    public var hasChanges: Bool {
        isLeftMissing || isRightMissing || changedCount > 0
    }
}

public enum ParagraphChange: Equatable, Sendable {
    case unchanged(String)
    case removed(String)
    case added(String)

    public var isUnchanged: Bool {
        if case .unchanged = self { return true }
        return false
    }
}
