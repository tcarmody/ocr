import Foundation

/// Multi-file search across an unpacked EPUB working tree. Returns
/// every match in every text-bearing file, with line + context, so
/// the editor can list them and let the user click through.
///
/// Source of truth for file contents is provided by the caller via
/// `contentProvider` so unsaved in-memory buffers can be searched
/// alongside on-disk files. The search itself is pure-Swift; no
/// XML parsing — we walk lines as raw text and let regex / substring
/// matching do the work.
public struct PackageSearch: Sendable {
    public init() {}

    public struct Hit: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let fileURL: URL
        public let fileName: String
        /// 1-based line number in the file's text.
        public let line: Int
        /// The full line (trimmed of surrounding newline) the match
        /// landed in. Used for the result-list preview.
        public let lineText: String
        /// Start column (UTF-16 offset) of the match within
        /// `lineText`.
        public let matchStart: Int
        /// Length of the match in UTF-16 units within `lineText`.
        public let matchLength: Int

        public init(
            id: UUID = UUID(),
            fileURL: URL,
            fileName: String,
            line: Int,
            lineText: String,
            matchStart: Int,
            matchLength: Int
        ) {
            self.id = id
            self.fileURL = fileURL
            self.fileName = fileName
            self.line = line
            self.lineText = lineText
            self.matchStart = matchStart
            self.matchLength = matchLength
        }
    }

    public enum SearchError: Error, LocalizedError {
        case invalidRegex(String)
        public var errorDescription: String? {
            switch self {
            case .invalidRegex(let msg): return "Invalid regex: \(msg)"
            }
        }
    }

    /// Run a search across `fileURLs`. Each file's text is fetched
    /// via `contentProvider(url)` — typically the editor passes a
    /// closure that returns the in-memory buffer for dirty files and
    /// disk content for clean ones.
    ///
    /// `query` is treated as a literal substring unless `regex` is
    /// true. `caseSensitive == false` is the default (lowercase
    /// search; matches `Foo` and `FOO` for `foo`).
    public func search(
        in fileURLs: [URL],
        query: String,
        caseSensitive: Bool = false,
        regex: Bool = false,
        contentProvider: (URL) -> String?,
        maxHits: Int = 1000
    ) throws -> [Hit] {
        guard !query.isEmpty else { return [] }

        // Compile the pattern once. Substring search is implemented
        // as a regex with literal escaping so the line-walk loop
        // stays uniform.
        let pattern: String = regex
            ? query
            : NSRegularExpression.escapedPattern(for: query)
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        let re: NSRegularExpression
        do {
            re = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw SearchError.invalidRegex(error.localizedDescription)
        }

        var hits: [Hit] = []
        for url in fileURLs {
            guard let content = contentProvider(url) else { continue }
            // Walk by line. `enumerateLines` gives us 1-based-friendly
            // line numbering when we increment as we go.
            var lineNumber = 0
            content.enumerateLines { line, stop in
                lineNumber += 1
                let nsLine = line as NSString
                let range = NSRange(location: 0, length: nsLine.length)
                let matches = re.matches(in: line, options: [], range: range)
                for match in matches {
                    hits.append(Hit(
                        fileURL: url,
                        fileName: url.lastPathComponent,
                        line: lineNumber,
                        lineText: line,
                        matchStart: match.range.location,
                        matchLength: match.range.length
                    ))
                    if hits.count >= maxHits {
                        stop = true
                        return
                    }
                }
            }
            if hits.count >= maxHits { break }
        }
        return hits
    }

    /// One file's worth of replacement output: the rewritten text +
    /// the number of substitutions that landed in this file.
    public struct ReplaceResult: Sendable, Equatable {
        public let fileURL: URL
        public let newContent: String
        public let replacementCount: Int

        public init(
            fileURL: URL,
            newContent: String,
            replacementCount: Int
        ) {
            self.fileURL = fileURL
            self.newContent = newContent
            self.replacementCount = replacementCount
        }
    }

    /// Replace every occurrence of `query` with `replacement` across
    /// `fileURLs`. Returns one `ReplaceResult` per file that had at
    /// least one match — files with zero matches are omitted.
    ///
    /// The caller is responsible for installing the new content
    /// (typically: write to the editor's in-memory buffer + mark
    /// dirty). This keeps the search engine pure: no I/O on the
    /// write side, and the editor's undo / save semantics stay in
    /// one place.
    ///
    /// **Replacement template syntax**: NSRegularExpression
    /// templates. Plain literals work for the common case ("fix this
    /// typo"). When `regex == true`, `$1`, `$2`, … reference capture
    /// groups; literal `$` must be escaped as `\$`. When `regex ==
    /// false`, the query is escaped but the replacement is **NOT**
    /// — you can still use `$0` etc. if you want, but typically a
    /// literal replacement string just works.
    public func replaceAll(
        in fileURLs: [URL],
        query: String,
        replacement: String,
        caseSensitive: Bool = false,
        regex: Bool = false,
        contentProvider: (URL) -> String?
    ) throws -> [ReplaceResult] {
        guard !query.isEmpty else { return [] }
        let pattern: String = regex
            ? query
            : NSRegularExpression.escapedPattern(for: query)
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        let re: NSRegularExpression
        do {
            re = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw SearchError.invalidRegex(error.localizedDescription)
        }
        // For non-regex search, callers usually want a literal
        // replacement — escape `$` and `\` so NSRegularExpression
        // treats the replacement as a literal string.
        let template: String = regex
            ? replacement
            : Self.escapeReplacementTemplate(replacement)

        var out: [ReplaceResult] = []
        for url in fileURLs {
            guard let content = contentProvider(url) else { continue }
            let mutable = NSMutableString(string: content)
            let range = NSRange(location: 0, length: mutable.length)
            let count = re.replaceMatches(
                in: mutable, options: [], range: range, withTemplate: template
            )
            if count > 0 {
                out.append(ReplaceResult(
                    fileURL: url,
                    newContent: mutable as String,
                    replacementCount: count
                ))
            }
        }
        return out
    }

    /// Escape `$` and `\` in `s` so it's safe to pass as an
    /// NSRegularExpression template even when the user wanted a
    /// literal replacement.
    static func escapeReplacementTemplate(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            if c == "\\" || c == "$" {
                out.append("\\")
            }
            out.append(c)
        }
        return out
    }

    /// Convenience: collect every text-bearing file in `workingDir`.
    /// Used as the default file set when the caller doesn't want to
    /// curate one. Includes XHTML, HTML, CSS, JS, OPF, NCX, plain
    /// .txt and .xml — anything Foundation can decode as UTF-8 that's
    /// reasonable to grep through. Skips images, fonts, EPUB
    /// metadata directories.
    public static func textFileURLs(in workingDir: URL) -> [URL] {
        let fm = FileManager.default
        let textExtensions: Set<String> = [
            "xhtml", "html", "htm", "css", "js",
            "opf", "ncx", "xml", "txt",
        ]
        var out: [URL] = []
        guard let enumerator = fm.enumerator(
            at: workingDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard textExtensions.contains(ext) else { continue }
            let isFile = (try? url.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile) ?? false
            guard isFile else { continue }
            out.append(url)
        }
        // Sort so chapter-001.xhtml comes before chapter-002.xhtml,
        // and so the result list is deterministic across runs.
        return out.sorted { $0.path < $1.path }
    }
}
