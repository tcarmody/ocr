import Foundation
import ArgumentParser
import Document
import Pipeline
import EPUB
import AI

/// `humanist-cli convert <input>` — turn one input file into one or more
/// output formats. Same engines as the SwiftUI app (Vision OCR, Surya
/// layout + tables, optional Claude / Tesseract, EPUB writers, etc.);
/// just a CLI surface on top.
///
/// Input formats (auto-detected by extension):
///   pdf · txt · md · markdown · rtf · html · htm · docx · doc · odt
///
/// Output formats (`-f` / `--formats`, comma-separated):
///   epub · md · txt · html · docx · searchable-pdf
struct ConvertCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert an input document into one or more output formats."
    )

    // MARK: - Positional + I/O

    @Argument(help: "Path to the input file (PDF, TXT, MD, RTF, HTML, DOCX, DOC, ODT).")
    var input: String

    @Option(name: [.short, .customLong("output-dir")],
            help: "Directory to write outputs into. Defaults to the input file's directory.")
    var outputDir: String?

    @Option(name: .customLong("output-name"),
            help: "Base filename (without extension) for outputs. Defaults to the input's basename.")
    var outputName: String?

    @Option(name: [.short, .customLong("formats")],
            parsing: .upToNextOption,
            help: "Output format(s). Repeat the flag or comma-separate: -f epub -f md, or -f epub,md.")
    var formats: [String] = ["epub"]

    @Option(name: [.customLong("output-suffix")],
            help: "Append this suffix to the output basename, e.g. \"--output-suffix claude\" → book-claude.epub.")
    var outputSuffix: String = ""

    // MARK: - Language / OCR knobs

    @Option(name: [.short, .customLong("language")],
            parsing: .upToNextOption,
            help: "Language code(s) for OCR (BCP-47, e.g. en, grc, la). Auto-detected when omitted.")
    var languages: [String] = []

    @Flag(name: .long, help: "Force OCR on every page, even when the embedded PDF text looks clean.")
    var forceOCR: Bool = false

    @Option(name: .long,
            help: "Per-page force-OCR override (1-based, comma-separated, with N-M ranges, e.g. \"1-20,150-160\").")
    var forceOCRPages: String = ""

    @Flag(name: .long, help: "Force Surya OCR on every region. Slower, higher accuracy on classical scripts.")
    var surya: Bool = false

    @Flag(name: .long, help: "Route page OCR through Claude Sonnet (cloud). Best on hard scripts; ~$15-25/book.")
    var claudePageOCR: Bool = false

    @Flag(name: .long, help: "Force facing-page bilingual handling: cross-link verso/recto spreads even when auto-detection would have given up.")
    var forceBilingualFacingPage: Bool = false

    // MARK: - Cloud / privacy

    @Flag(name: .long, help: "Force Private mode: disable every Cloud feature even if API key is set.")
    var `private`: Bool = false

    @Option(name: [.customLong("api-key-env")],
            help: "Env var to read the Anthropic API key from. Defaults to ANTHROPIC_API_KEY.")
    var apiKeyEnv: String = "ANTHROPIC_API_KEY"

    // MARK: - Per-feature Cloud toggles (default ON in cloud mode, --no-X disables)

    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "Use Claude Sonnet for hard-region OCR (cloud mode only).")
    var claudeOCR: Bool = true

    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "Use Claude Sonnet for table extraction (cloud mode only).")
    var claudeTables: Bool = true

    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "Use Claude Haiku for post-OCR character cleanup (cloud mode only).")
    var claudeCleanup: Bool = true

    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "Use Claude Haiku to parse the printed Table of Contents (cloud mode only).")
    var claudeTOC: Bool = true

    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "Use Claude Haiku to label each chapter's epub:type (cloud mode only).")
    var semanticClassification: Bool = true

    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "Use Claude Haiku to identify recurring OCR errors document-wide (cloud mode only).")
    var coherencePass: Bool = true

    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "Use Claude Haiku to extract title/author/year/publisher/ISBN (cloud mode only).")
    var metadataExtraction: Bool = true

    // MARK: - Logging

    @Flag(name: [.short, .long], help: "Errors only.")
    var quiet: Bool = false

    @Flag(name: [.short, .long], help: "Per-page detail.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Emit newline-delimited JSON events on stdout.")
    var json: Bool = false

    @Flag(name: .long, help: "Keep the per-page debug staging directory after conversion.")
    var debug: Bool = false

    // MARK: - Run

    mutating func run() async throws {
        // Validate input file
        let inputURL = URL(fileURLWithPath: input).standardizedFileURL
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ValidationError("Input file not found: \(input)")
        }

        // Resolve output paths
        let outputDirURL = (outputDir.map { URL(fileURLWithPath: $0) }
                            ?? inputURL.deletingLastPathComponent()).standardizedFileURL
        try? FileManager.default.createDirectory(
            at: outputDirURL, withIntermediateDirectories: true
        )

        let baseStem = outputName ?? inputURL.deletingPathExtension().lastPathComponent
        let stem = outputSuffix.isEmpty ? baseStem : "\(baseStem) \(outputSuffix)"

        // Parse formats (allow both repeated and comma-separated forms)
        let parsedFormats = try parseFormats(formats)
        guard !parsedFormats.isEmpty else {
            throw ValidationError("No output formats requested. Use --formats to specify at least one.")
        }

        // Reporter
        let reporterMode: ProgressReporter.Mode =
            json ? .json : (quiet ? .quiet : (verbose ? .verbose : .default))
        let reporter = ProgressReporter(mode: reporterMode)

        // Dispatch by input type
        let ext = inputURL.pathExtension.lowercased()
        if ext == "pdf" {
            try await runPDFConversion(
                inputURL: inputURL,
                outputDir: outputDirURL,
                stem: stem,
                formats: parsedFormats,
                reporter: reporter
            )
        } else if DocumentIngest.isSupported(inputURL) {
            // Non-PDF input — searchable-pdf isn't producible from
            // these. Reject up front rather than silently skipping.
            if parsedFormats.contains(.searchablePdf) {
                throw ValidationError(
                    "searchable-pdf output requires a PDF input. Got .\(ext)."
                )
            }
            try await runDocumentConversion(
                inputURL: inputURL,
                outputDir: outputDirURL,
                stem: stem,
                formats: parsedFormats,
                reporter: reporter
            )
        } else {
            throw ValidationError("Unsupported input format: .\(ext)")
        }
    }

    // MARK: - PDF path

    private func runPDFConversion(
        inputURL: URL, outputDir: URL, stem: String,
        formats: Set<OutputFormat>, reporter: ProgressReporter
    ) async throws {
        reporter.note("Converting \(inputURL.lastPathComponent) → \(formats.map(\.rawValue).sorted().joined(separator: ", "))")

        // Build pipeline options from CLI flags. The pipeline always
        // writes the EPUB internally; siblings are gated on the
        // emit* flags. Anything we ask for that doesn't match a
        // pipeline flag (e.g. txt-only without md) we trim manually
        // after the run.
        let processingMode: ProcessingMode = self.private ? .privateLocal : .cloud
        let cloudFeatures = AISettings.CloudFeatures(
            hardRegionOCR: !self.private && claudeOCR,
            tableExtraction: !self.private && claudeTables,
            postOCRCleanup: !self.private && claudeCleanup,
            postOCRCleanupVisionMode: false,
            semanticClassification: !self.private && semanticClassification,
            tocParsing: !self.private && claudeTOC,
            metadataExtraction: !self.private && metadataExtraction,
            coherencePass: !self.private && coherencePass,
            adaptivePageRouting: true,
            useBatchAPI: false,
            parallelPageOCRConcurrency: 1
        )
        let bcp47Languages: [BCP47] = languages.isEmpty ? [.en] : languages.map { BCP47($0) }
        let forceOCRPageRanges = PageRangeParser.parse(self.forceOCRPages)

        let outputEPUBURL = outputDir.appendingPathComponent("\(stem).epub")
        let txtURL  = outputDir.appendingPathComponent("\(stem).txt")
        let mdURL   = outputDir.appendingPathComponent("\(stem).md")
        let htmlURL = outputDir.appendingPathComponent("\(stem).html")
        let docxURL = outputDir.appendingPathComponent("\(stem).docx")
        let pdfURL  = outputDir.appendingPathComponent("\(stem).searchable.pdf")

        let options = PDFToEPUBPipeline.Options(
            languages: bcp47Languages,
            emitDebugLog: debug,
            useHighAccuracyOCR: surya,
            forceOCR: forceOCR,
            processingMode: processingMode,
            cloudFeatures: cloudFeatures,
            anthropicAPIKeyProvider: { [apiKeyEnv] in
                ProcessInfo.processInfo.environment[apiKeyEnv]
            },
            useWholePageOCR: claudePageOCR,
            emitSiblingTextOutputs: formats.contains(.txt) || formats.contains(.md),
            emitSiblingDocuments: formats.contains(.html) || formats.contains(.docx),
            forceOCRPageRanges: forceOCRPageRanges,
            siblingTextURLOverride: txtURL,
            siblingMarkdownURLOverride: mdURL,
            siblingHTMLURLOverride: htmlURL,
            siblingDOCXURLOverride: docxURL,
            emitSearchablePDF: formats.contains(.searchablePdf),
            searchablePDFURLOverride: pdfURL,
            forceBilingualFacingPage: forceBilingualFacingPage
        )

        let pipeline = PDFToEPUBPipeline()
        let stats = try await pipeline.convert(
            pdfURL: inputURL,
            outputURL: outputEPUBURL,
            options: options,
            progress: { @Sendable progress in reporter.handle(progress) }
        )

        // Trim outputs the user didn't ask for. The pipeline writes
        // pairs as a unit (txt+md together, html+docx together); we
        // delete the unwanted half here and remove the EPUB if it
        // wasn't requested.
        if !formats.contains(.epub) {
            try? FileManager.default.removeItem(at: outputEPUBURL)
        } else {
            reporter.wrote(outputEPUBURL)
        }
        for (format, url) in [
            (OutputFormat.txt, txtURL), (OutputFormat.md, mdURL),
            (OutputFormat.html, htmlURL), (OutputFormat.docx, docxURL),
            (OutputFormat.searchablePdf, pdfURL),
        ] {
            if formats.contains(format) {
                if FileManager.default.fileExists(atPath: url.path) {
                    reporter.wrote(url)
                }
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }

        reporter.summary(stats: stats)
    }

    // MARK: - Document-ingest path (non-PDF)

    private func runDocumentConversion(
        inputURL: URL, outputDir: URL, stem: String,
        formats: Set<OutputFormat>, reporter: ProgressReporter
    ) async throws {
        reporter.note("Ingesting \(inputURL.lastPathComponent) → \(formats.map(\.rawValue).sorted().joined(separator: ", "))")

        let language: BCP47 = languages.first.map { BCP47($0) } ?? .en
        let book = try DocumentIngest().ingest(from: inputURL, language: language)

        for format in formats.sorted(by: { $0.rawValue < $1.rawValue }) {
            let url = outputDir.appendingPathComponent("\(stem).\(format.fileExtension)")
            switch format {
            case .epub:
                try EPUBBuilder().write(
                    book: book, sourcePDFURL: inputURL, to: url
                )
            case .txt:
                try PlainTextWriter.render(book).write(
                    to: url, atomically: true, encoding: .utf8
                )
            case .md:
                try MarkdownWriter.render(book).write(
                    to: url, atomically: true, encoding: .utf8
                )
            case .html:
                try HTMLWriter.render(book).write(
                    to: url, atomically: true, encoding: .utf8
                )
            case .docx:
                try DOCXWriter.write(book, to: url)
            case .searchablePdf:
                // Already filtered out by run(); defensive.
                continue
            }
            reporter.wrote(url)
        }
        reporter.summary(stats: nil)
    }

    // MARK: - Format parsing

    private func parseFormats(_ raw: [String]) throws -> Set<OutputFormat> {
        var out = Set<OutputFormat>()
        for entry in raw {
            for token in entry.split(separator: ",").map({
                $0.trimmingCharacters(in: .whitespaces)
            }) where !token.isEmpty {
                guard let f = OutputFormat(rawValue: token) else {
                    throw ValidationError(
                        "Unknown output format: \(token). Valid: \(OutputFormat.allCases.map(\.rawValue).joined(separator: ", "))"
                    )
                }
                out.insert(f)
            }
        }
        return out
    }
}
