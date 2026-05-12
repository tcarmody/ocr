import Foundation
import ArgumentParser
import AI
import Document
import EPUB
import Pipeline

/// `humanist-cli compare-corpus <dir>` — walk a directory of paired
/// PDFs + reference EPUBs (publisher-edited; e.g. an O'Reilly PDF
/// next to the matching O'Reilly EPUB), convert each PDF through
/// the full conversion pipeline, and diff the result against the
/// reference. Emits a per-book + aggregate quality report that
/// surfaces regressions before tagging a release.
///
/// Pairing is by filename stem with version-suffix stripping —
/// `low-codeai_V4.pdf` matches `low-codeai.epub`. Unpaired files
/// are listed in the report and skipped.
///
/// The corpus harness is intentionally local-only — these are
/// usually copyrighted publisher EPUBs that can't ship in the
/// repo or with the app. The `--dir` argument is required so the
/// developer always picks the path explicitly.
struct CompareCorpusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare-corpus",
        abstract: "Run the conversion pipeline on every PDF in a corpus and diff against matching reference EPUBs."
    )

    @Option(name: [.short, .customLong("dir")],
            help: "Corpus directory. Should contain PDF + EPUB pairs matched by filename stem.")
    var directory: String

    @Option(name: .long, help: "Convert at most N PDFs (alphabetical). Useful for iteration on metric tuning.")
    var limit: Int?

    @Option(name: .long, help: "Keep converted output EPUBs in this directory for inspection.")
    var keepOutput: String?

    @Flag(name: .long, help: "Force Private mode: skip every Cloud feature.")
    var `private`: Bool = false

    @Option(name: [.customLong("api-key-env")],
            help: "Environment variable holding the Anthropic API key (default ANTHROPIC_API_KEY).")
    var apiKeyEnv: String = "ANTHROPIC_API_KEY"

    @Flag(name: .long, help: "Emit machine-readable JSON instead of the text table.")
    var json: Bool = false

    func run() async throws {
        let root = URL(fileURLWithPath: directory).standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ValidationError("Corpus directory not found: \(directory)")
        }

        // iCloud-safe enumeration. `FileManager.skipsHiddenFiles` on
        // iCloud Drive paths returns empty arrays because the
        // parent's dot-prefixed metadata + iCloud xattrs trip a
        // bug in FileManager's hidden-file filter — see
        // `feedback_filemanager_icloud_skips_hidden.md`. Pass
        // `[]` and filter by extension manually.
        let allEntries: [URL]
        do {
            allEntries = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw ValidationError(
                "Couldn't enumerate corpus directory: "
                + error.localizedDescription
            )
        }
        let pdfs = allEntries
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let epubs = allEntries
            .filter { $0.pathExtension.lowercased() == "epub" }
        guard !pdfs.isEmpty else {
            throw ValidationError(
                "No PDFs found in corpus directory: \(root.path)"
            )
        }

        // Build stem → reference URL index.
        var refByStem: [String: URL] = [:]
        for epub in epubs {
            refByStem[Self.normalizedStem(of: epub)] = epub
        }

        // Pair PDFs with references.
        var pairs: [(pdf: URL, ref: URL?)] = []
        for pdf in pdfs {
            let stem = Self.normalizedStem(of: pdf)
            pairs.append((pdf, refByStem[stem]))
        }
        if let limit, limit > 0 {
            pairs = Array(pairs.prefix(limit))
        }

        // Output dir for converted EPUBs. Either a user-supplied
        // path that persists or a temp dir we'll clean up at exit.
        let outputDir: URL
        let shouldCleanOutput: Bool
        if let keepOutput {
            outputDir = URL(fileURLWithPath: keepOutput)
                .standardizedFileURL
            try? FileManager.default.createDirectory(
                at: outputDir, withIntermediateDirectories: true
            )
            shouldCleanOutput = false
        } else {
            outputDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "humanist-corpus-\(UUID().uuidString)"
                )
            try? FileManager.default.createDirectory(
                at: outputDir, withIntermediateDirectories: true
            )
            shouldCleanOutput = true
        }
        defer {
            if shouldCleanOutput {
                try? FileManager.default.removeItem(at: outputDir)
            }
        }

        // Convert + diff.
        var rows: [CorpusComparison?] = []
        var orphanPDFs: [String] = []
        let stderr = FileHandle.standardError

        for (pdf, ref) in pairs {
            let stem = Self.normalizedStem(of: pdf)
            stderr.write(Data(
                "[\(rows.count + 1)/\(pairs.count)] \(pdf.lastPathComponent) → ".utf8
            ))
            guard let ref else {
                stderr.write(Data("no reference EPUB; skipping\n".utf8))
                orphanPDFs.append(pdf.lastPathComponent)
                rows.append(nil)
                continue
            }

            // Convert.
            let outURL = outputDir
                .appendingPathComponent("\(stem).epub")
            do {
                try await Self.convert(
                    pdf: pdf, output: outURL,
                    `private`: self.private,
                    apiKeyEnv: apiKeyEnv
                )
            } catch {
                stderr.write(Data(
                    "convert failed: \(error.localizedDescription)\n".utf8
                ))
                rows.append(nil)
                continue
            }

            // Extract + diff.
            do {
                let actual = try CorpusMetricsExtractor.extract(from: outURL)
                let reference = try CorpusMetricsExtractor.extract(from: ref)
                let comparison = CorpusComparison(
                    bookStem: stem,
                    actual: actual,
                    reference: reference
                )
                rows.append(comparison)
                stderr.write(Data(
                    String(
                        format: "Jaccard %.2f, char ratio %.2f\n",
                        comparison.wordSetJaccard,
                        comparison.characterCountRatio ?? 0
                    ).utf8
                ))
            } catch {
                stderr.write(Data(
                    "metrics failed: \(error.localizedDescription)\n".utf8
                ))
                rows.append(nil)
            }
        }

        // Report.
        if json {
            print(Self.jsonReport(rows: rows, orphans: orphanPDFs))
        } else {
            print(Self.textReport(rows: rows, orphans: orphanPDFs))
        }
    }

    // MARK: - Stem matching

    /// Strip filename of common version suffixes (`_V4`, `_V2`,
    /// `_secondedition_V4`) so an O'Reilly EPUB and the PDF that
    /// represents the same edition pair correctly even when the
    /// PDF stem carries a version tag that the EPUB stem doesn't.
    /// Pure-text helper; exposed `internal` so tests can pin it.
    static func normalizedStem(of url: URL) -> String {
        var stem = url.deletingPathExtension().lastPathComponent
        stem = stem.lowercased()
        // Drop trailing `_V<digits>` segments — common in
        // publisher review PDFs.
        let trailingVersion = try? NSRegularExpression(
            pattern: "_v\\d+$", options: []
        )
        if let regex = trailingVersion {
            let ns = stem as NSString
            stem = regex.stringByReplacingMatches(
                in: stem,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: ""
            )
        }
        return stem
    }

    // MARK: - Conversion

    private static func convert(
        pdf: URL,
        output: URL,
        `private`: Bool,
        apiKeyEnv: String
    ) async throws {
        // Use the user's existing AI defaults so cloud features
        // they've enabled in the SwiftUI app apply here too.
        // Force Private overrides them all when `--private`.
        let stored = AISettingsStore().load()
        let processingMode: ProcessingMode = `private`
            ? .privateLocal
            : stored.processingMode
        let cloudFeatures = `private`
            ? AISettings.CloudFeatures(
                hardRegionOCR: false,
                tableExtraction: false,
                postOCRCleanup: false,
                postOCRCleanupVisionMode: false,
                semanticClassification: false,
                tocParsing: false,
                metadataExtraction: false,
                coherencePass: false,
                adaptivePageRouting: true,
                useBatchAPI: false,
                parallelPageOCRConcurrency: 1
            )
            : stored.cloudFeatures
        let options = PDFToEPUBPipeline.Options(
            languages: [.en],
            emitDebugLog: false,
            useHighAccuracyOCR: false,
            forceOCR: false,
            processingMode: processingMode,
            cloudFeatures: cloudFeatures,
            anthropicAPIKeyProvider: { [apiKeyEnv] in
                ProcessInfo.processInfo.environment[apiKeyEnv]
            },
            useClaudePageOCR: false,
            emitSiblingTextOutputs: false,
            emitSiblingDocuments: false,
            forceOCRPageRanges: [],
            siblingTextURLOverride: nil,
            siblingMarkdownURLOverride: nil,
            siblingHTMLURLOverride: nil,
            siblingDOCXURLOverride: nil,
            emitSearchablePDF: false,
            searchablePDFURLOverride: nil
        )
        let pipeline = PDFToEPUBPipeline()
        _ = try await pipeline.convert(
            pdfURL: pdf,
            outputURL: output,
            options: options,
            progress: nil
        )
    }

    // MARK: - Reporting

    private static func textReport(
        rows: [CorpusComparison?],
        orphans: [String]
    ) -> String {
        var out = ""
        out += "\nCorpus comparison — \(rows.compactMap { $0 }.count) of \(rows.count) books diffable\n"
        out += String(repeating: "─", count: 80) + "\n"
        out += Self.padRight("book", to: 50)
            + "  " + Self.padLeft("jacc", to: 5)
            + "  " + Self.padLeft("char%", to: 5)
            + "  " + Self.padLeft("Δpara", to: 6)
            + "  " + Self.padLeft("Δcode", to: 6) + "\n"
        out += String(repeating: "─", count: 80) + "\n"
        for row in rows {
            guard let r = row else { continue }
            let charPct = r.characterCountRatio.map {
                String(format: "%.0f", $0 * 100)
            } ?? "—"
            let para = r.paragraphDelta
            let code = r.actual.inlineCodeCount - r.reference.inlineCodeCount
            let stem = String(r.bookStem.prefix(50))
            let jaccard = String(format: "%.2f", r.wordSetJaccard)
            let paraStr = String(format: "%+d", para)
            let codeStr = String(format: "%+d", code)
            out += Self.padRight(stem, to: 50)
                + "  " + Self.padLeft(jaccard, to: 5)
                + "  " + Self.padLeft(charPct, to: 5)
                + "  " + Self.padLeft(paraStr, to: 6)
                + "  " + Self.padLeft(codeStr, to: 6) + "\n"
        }

        // Aggregate.
        let diffable = rows.compactMap { $0 }
        if !diffable.isEmpty {
            out += String(repeating: "─", count: 80) + "\n"
            let medianJaccard = Self.median(diffable.map(\.wordSetJaccard))
            let medianCharRatio = Self.median(
                diffable.compactMap(\.characterCountRatio)
            )
            let codeRetentionAvg = Self.mean(
                diffable.compactMap { $0.retention(\.inlineCodeCount) }
            )
            let preRetentionAvg = Self.mean(
                diffable.compactMap { $0.retention(\.preCount) }
            )
            let emRetentionAvg = Self.mean(
                diffable.compactMap { $0.retention(\.inlineEmCount) }
            )
            let strongRetentionAvg = Self.mean(
                diffable.compactMap { $0.retention(\.inlineStrongCount) }
            )
            out += "\nAggregate:\n"
            out += String(
                format: "  median Jaccard word similarity     %.2f\n",
                medianJaccard
            )
            out += String(
                format: "  median character-count ratio       %.2f\n",
                medianCharRatio
            )
            out += String(
                format: "  mean <code> retention              %.2f\n",
                codeRetentionAvg
            )
            out += String(
                format: "  mean <pre> retention               %.2f\n",
                preRetentionAvg
            )
            out += String(
                format: "  mean <em> retention                %.2f\n",
                emRetentionAvg
            )
            out += String(
                format: "  mean <strong> retention            %.2f\n",
                strongRetentionAvg
            )
        }

        if !orphans.isEmpty {
            out += "\nPDFs with no matching reference EPUB:\n"
            for o in orphans { out += "  • \(o)\n" }
        }
        return out
    }

    private static func jsonReport(
        rows: [CorpusComparison?],
        orphans: [String]
    ) -> String {
        // Minimal JSON shape — opt-in via --json for scripts.
        var dicts: [[String: Any]] = []
        for row in rows {
            guard let r = row else { continue }
            dicts.append([
                "book": r.bookStem,
                "jaccard": r.wordSetJaccard,
                "char_ratio": r.characterCountRatio ?? 0,
                "delta_paragraphs": r.paragraphDelta,
                "delta_figures": r.figureDelta,
                "delta_tables": r.tableDelta,
                "code_retention": r.retention(\.inlineCodeCount) ?? -1,
                "pre_retention": r.retention(\.preCount) ?? -1,
                "em_retention": r.retention(\.inlineEmCount) ?? -1,
                "strong_retention": r.retention(\.inlineStrongCount) ?? -1,
            ])
        }
        let payload: [String: Any] = [
            "books": dicts,
            "orphans": orphans,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ), let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Pad / truncate a Swift String to a fixed width. Used by the
    /// text report — Swift strings can't be passed to `String(format:)`
    /// `%s` specifiers (that takes a C string, and bridging is
    /// unsafe). Build the table by hand instead.
    static func padRight(_ s: String, to width: Int) -> String {
        if s.count >= width { return String(s.prefix(width)) }
        return s + String(repeating: " ", count: width - s.count)
    }

    static func padLeft(_ s: String, to width: Int) -> String {
        if s.count >= width { return String(s.prefix(width)) }
        return String(repeating: " ", count: width - s.count) + s
    }
}
