import Foundation
import EPUB

/// R-Bulk-Editor (v1). Runs a find/replace pass across multiple
/// .epub files in one shot. For each EPUB: open into a temp
/// working tree, run `PackageSearch.replaceAll` over every text
/// file, write changes back to disk, repack the EPUB in place.
///
/// In-place save mirrors the existing single-EPUB editor save —
/// the user has Time Machine / version control if they want
/// backups. Repacking writes via the existing `EPUBRepacker`
/// path so the resulting archive is byte-clean (mimetype first,
/// stored uncompressed).
///
/// Re-OCR-by-language across books is intentionally out of scope
/// for v1 — that's a much larger feature that re-engages the
/// conversion pipeline. Cross-book find/replace is the higher-
/// utility piece; it lands first.
public struct BulkEditor {

    public struct Result: Sendable, Equatable {
        public let epubURL: URL
        /// Map of inner-file URL → number of replacements made in
        /// that file. Empty when nothing matched in this book.
        public let replacementsByFile: [URL: Int]
        /// Set when this EPUB failed to open / repack / save. The
        /// other entries in the batch keep going regardless of
        /// per-book failures.
        public let error: String?

        public var totalReplacements: Int {
            replacementsByFile.values.reduce(0, +)
        }
        public var fileCount: Int {
            replacementsByFile.count
        }
    }

    public init() {}

    /// Run `query` → `replacement` across every text file in each
    /// EPUB at `epubURLs`. Returns one `Result` per input EPUB
    /// (in input order). EPUBs that fail to open / repack are
    /// reported via the `error` field; other books in the batch
    /// keep going.
    ///
    /// `progress` is invoked on the calling actor before each
    /// EPUB starts, with the index + URL — the Library window's
    /// Bulk Edit sheet uses it to drive a per-book progress
    /// indicator.
    public func replace(
        in epubURLs: [URL],
        query: String,
        replacement: String,
        caseSensitive: Bool = false,
        regex: Bool = false,
        progress: ((Int, URL) -> Void)? = nil
    ) -> [Result] {
        guard !query.isEmpty else {
            return epubURLs.map {
                Result(epubURL: $0, replacementsByFile: [:], error: nil)
            }
        }
        var out: [Result] = []
        out.reserveCapacity(epubURLs.count)
        for (idx, url) in epubURLs.enumerated() {
            progress?(idx, url)
            out.append(processOne(
                epubURL: url,
                query: query, replacement: replacement,
                caseSensitive: caseSensitive, regex: regex
            ))
        }
        return out
    }

    private func processOne(
        epubURL: URL,
        query: String, replacement: String,
        caseSensitive: Bool, regex: Bool
    ) -> Result {
        let pkg: EPUBPackage
        do {
            pkg = try EPUBPackage.open(epubURL: epubURL)
        } catch {
            return Result(
                epubURL: epubURL,
                replacementsByFile: [:],
                error: "Couldn't open: \(error.localizedDescription)"
            )
        }
        let textFiles = PackageSearch.textFileURLs(in: pkg.workingDirectory)
        let search = PackageSearch()
        let results: [PackageSearch.ReplaceResult]
        do {
            results = try search.replaceAll(
                in: textFiles,
                query: query,
                replacement: replacement,
                caseSensitive: caseSensitive,
                regex: regex,
                contentProvider: { try? String(contentsOf: $0, encoding: .utf8) }
            )
        } catch {
            return Result(
                epubURL: epubURL,
                replacementsByFile: [:],
                error: "Search failed: \(error.localizedDescription)"
            )
        }
        // Write each modified file back into the working tree.
        // Skip the repack entirely if no replacements happened —
        // touching the .epub for zero-change books would just
        // change mtimes without value.
        guard !results.isEmpty else {
            return Result(
                epubURL: epubURL,
                replacementsByFile: [:],
                error: nil
            )
        }
        var counts: [URL: Int] = [:]
        do {
            for r in results {
                try r.newContent.write(
                    to: r.fileURL, atomically: true, encoding: .utf8
                )
                counts[r.fileURL] = r.replacementCount
            }
        } catch {
            return Result(
                epubURL: epubURL,
                replacementsByFile: [:],
                error: "Couldn't write changes: \(error.localizedDescription)"
            )
        }
        // Repack in place. EPUBRepacker writes to a temp file then
        // renames over the destination so an interrupted repack
        // doesn't leave a half-written archive.
        do {
            try EPUBRepacker().repack(
                workingDirectory: pkg.workingDirectory,
                to: epubURL
            )
        } catch {
            return Result(
                epubURL: epubURL,
                replacementsByFile: counts,
                error: "Repack failed: \(error.localizedDescription)"
            )
        }
        return Result(
            epubURL: epubURL,
            replacementsByFile: counts,
            error: nil
        )
    }
}
