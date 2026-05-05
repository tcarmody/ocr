import Foundation
import AppKit  // NSAttributedString RTF parsing
import CoreGraphics
import PDFKit
import AI
import Document
import EPUB
import Pipeline
import ZIPFoundation

/// Cloud-mode validation spike (Phase 4 in the migration plan).
///
/// Runs the full pipeline twice on a hand-corrected fixture:
///   1. `.privateLocal` — Vision → Surya → Tesseract.
///   2. `.cloud`        — adds Claude (Sonnet) as Stage 3.
///
/// Compares each output against a UTF-8 reference text (decoded from
/// an RTF) using character error rate (Levenshtein over normalized
/// strings). Writes a Markdown report into `Tools/spike-results/`.
///
/// Not part of `swift test` — this hits the live Anthropic API and
/// spends tokens. Invoke explicitly with `swift run SpikeRunner`.
@main
struct SpikeRunner {
    // Hardcoded fixture paths for v1. When Hebrew / Latin ground
    // truth lands we'll parameterize these via CLI flags.
    static let pdfPath  = "/Users/tim/Desktop/Aeschylus.pdf"
    static let rtfPath  = "/Users/tim/Desktop/Aeschylus.rtf"
    static let language = BCP47("grc")
    static let reportPath = "Tools/spike-results/aeschylus-greek-2026-05-05.md"

    static func main() async throws {
        // ── Setup ─────────────────────────────────────────────────
        log("loading ground truth from \(rtfPath)")
        let groundTruth = try loadRTF(at: rtfPath)
        let normGT = normalize(groundTruth)
        log("  ground-truth chars: \(groundTruth.count) (normalized: \(normGT.count))")

        // The source PDF is born-digital with a clean embedded text
        // layer — that's great for normal conversion, but defeats
        // the spike (the pipeline's `.trust` branch skips OCR
        // entirely). Rasterize to an image-only PDF first to force
        // the reocr branch through Vision → Surya → Tesseract → Claude.
        log("rasterizing source PDF (forces OCR path) …")
        let rasterizedURL = try rasterize(pdfPath: pdfPath, dpi: 300)
        defer { try? FileManager.default.removeItem(at: rasterizedURL) }
        log("  rasterized → \(rasterizedURL.path)")
        let workingPDFPath = rasterizedURL.path

        // API key: env var first, keychain fallback.
        let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        let storeKey = AnthropicAPIKeyStore().read()
        let apiKey = envKey ?? storeKey

        // ── Run 1: .privateLocal ──────────────────────────────────
        log("running .privateLocal …")
        let privateStart = Date()
        let privateText = try await runConversion(
            pdfPath: workingPDFPath,
            language: language,
            mode: .privateLocal,
            apiKey: apiKey,
            emitDebugLog: false
        )
        let privateElapsed = Date().timeIntervalSince(privateStart)
        let normPrivate = normalize(privateText)
        let privateDistance = levenshtein(normGT, normPrivate)
        let privateCER = Double(privateDistance) / Double(max(normGT.count, 1))
        log("  privateLocal: \(normPrivate.count) chars, CER \(String(format: "%.3f", privateCER)), \(String(format: "%.1f", privateElapsed))s")

        // ── Run 2: .cloud (only if we have a key) ─────────────────
        let cloudResult: CloudResult?
        if let apiKey, !apiKey.isEmpty {
            log("running .cloud …")
            let cloudStart = Date()
            let (cloudText, claudeCallCount) = try await runConversionCloud(
                pdfPath: workingPDFPath,
                language: language,
                apiKey: apiKey
            )
            let cloudElapsed = Date().timeIntervalSince(cloudStart)
            let normCloud = normalize(cloudText)
            let cloudDistance = levenshtein(normGT, normCloud)
            let cloudCER = Double(cloudDistance) / Double(max(normGT.count, 1))
            log("  cloud: \(normCloud.count) chars, CER \(String(format: "%.3f", cloudCER)), \(String(format: "%.1f", cloudElapsed))s, \(claudeCallCount) Claude obs")
            cloudResult = CloudResult(
                text: cloudText,
                normChars: normCloud.count,
                editDistance: cloudDistance,
                cer: cloudCER,
                elapsed: cloudElapsed,
                claudeObservations: claudeCallCount
            )
        } else {
            log("no API key (env or keychain) — skipping .cloud run")
            cloudResult = nil
        }

        // ── Report ────────────────────────────────────────────────
        let report = makeReport(
            pdfPath: pdfPath,
            language: language,
            groundTruthChars: normGT.count,
            privateResult: PrivateResult(
                text: privateText,
                normChars: normPrivate.count,
                editDistance: privateDistance,
                cer: privateCER,
                elapsed: privateElapsed
            ),
            cloudResult: cloudResult
        )
        let reportURL = URL(fileURLWithPath: reportPath)
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
        log("wrote \(reportPath)")
    }

    // MARK: - Conversion runners

    /// `.privateLocal` and `.cloud` share the same pipeline call shape.
    /// Cloud mode uses the dedicated runner below to also surface the
    /// Claude observation count via the debug log (proxy for "calls
    /// the cascade granted Stage 3").
    static func runConversion(
        pdfPath: String,
        language: BCP47,
        mode: ProcessingMode,
        apiKey: String?,
        emitDebugLog: Bool
    ) async throws -> String {
        let pdfURL = URL(fileURLWithPath: pdfPath)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("spike-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        var features = AISettings.CloudFeatures()
        features.hardRegionOCR = (mode == .cloud)

        let key = apiKey ?? ""
        let options = PDFToEPUBPipeline.Options(
            languages: [language],
            ocrQuality: .accurate,
            emitDebugLog: emitDebugLog,
            processingMode: mode,
            cloudFeatures: features,
            perBookCallCap: 200,
            anthropicAPIKeyProvider: { mode == .cloud ? key : nil }
        )

        let pipeline = PDFToEPUBPipeline()
        try await pipeline.convert(
            pdfURL: pdfURL,
            outputURL: outputURL,
            options: options
        )
        return try extractTextFromEPUB(at: outputURL)
    }

    /// Runs the cloud conversion with debug-log emission so we can
    /// count `.claude`-source observations afterward. Returns
    /// (extracted text, claude observation count).
    static func runConversionCloud(
        pdfPath: String,
        language: BCP47,
        apiKey: String
    ) async throws -> (String, Int) {
        let pdfURL = URL(fileURLWithPath: pdfPath)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("spike-cloud-\(UUID().uuidString).epub")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            // Debug folder lives alongside the EPUB.
            let debugFolder = outputURL.deletingPathExtension()
                .appendingPathExtension("humanist-debug")
            try? FileManager.default.removeItem(at: debugFolder)
        }

        var features = AISettings.CloudFeatures()
        features.hardRegionOCR = true

        let options = PDFToEPUBPipeline.Options(
            languages: [language],
            ocrQuality: .accurate,
            emitDebugLog: true,
            processingMode: .cloud,
            cloudFeatures: features,
            perBookCallCap: 200,
            anthropicAPIKeyProvider: { apiKey }
        )

        let pipeline = PDFToEPUBPipeline()
        try await pipeline.convert(
            pdfURL: pdfURL,
            outputURL: outputURL,
            options: options
        )
        let text = try extractTextFromEPUB(at: outputURL)

        // Count `.claude`-source observations in the debug log.
        // Format: `[KEEP] 0/12 c (0.10, ...) | text` — `src=c` ⇒ Claude.
        let logURL = outputURL.deletingPathExtension()
            .appendingPathExtension("humanist-debug")
            .appendingPathComponent("log.txt")
        let claudeCount = countClaudeObservations(at: logURL)
        return (text, claudeCount)
    }

    static func countClaudeObservations(at logURL: URL) -> Int {
        guard let log = try? String(contentsOf: logURL, encoding: .utf8) else {
            return 0
        }
        // Each observation line: "[FATE] page/idx src ..." where src
        // is one of v / t / s / e / c. Count lines where a `c` appears
        // in the source-letter column.
        let pattern = #"^\[(?:KEEP|DROP[^\]]*)\]\s+\d+/\s*\d+\s+c\s"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.anchorsMatchLines]
        ) else { return 0 }
        let range = NSRange(log.startIndex..., in: log)
        return regex.numberOfMatches(in: log, options: [], range: range)
    }

    // MARK: - Rasterize (force OCR path)

    enum SpikeError: Error, LocalizedError {
        case pdfOpenFailed(String)
        case pdfContextCreationFailed
        var errorDescription: String? {
            switch self {
            case .pdfOpenFailed(let p):       return "Could not open PDF at \(p)"
            case .pdfContextCreationFailed:   return "Could not create rasterized-PDF context"
            }
        }
    }

    /// Render every page of `pdfPath` at the given DPI and emit a new
    /// PDF whose pages are image XObjects only — no embedded text
    /// layer. The pipeline's `EmbeddedTextQualityScorer` then can't
    /// `.trust` the page, and the reocr branch fires through the
    /// full Vision → Surya → Tesseract → Claude cascade.
    static func rasterize(pdfPath: String, dpi: CGFloat) throws -> URL {
        let sourceURL = URL(fileURLWithPath: pdfPath)
        guard let document = PDFDocument(url: sourceURL) else {
            throw SpikeError.pdfOpenFailed(pdfPath)
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("spike-rasterized-\(UUID().uuidString).pdf")

        // Use first page's media box as a hint to the PDF context;
        // each page's actual size is set inside the per-page loop.
        guard let firstPage = document.page(at: 0) else {
            throw SpikeError.pdfOpenFailed("no pages")
        }
        var firstBox = firstPage.bounds(for: .mediaBox)

        guard let ctx = CGContext(
            outputURL as CFURL, mediaBox: &firstBox, nil
        ) else {
            throw SpikeError.pdfContextCreationFailed
        }

        let scale = dpi / 72.0
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let pageInfo = [
                kCGPDFContextMediaBox as String: NSValue(rect: box)
            ]
            ctx.beginPDFPage(pageInfo as CFDictionary)

            let pixelW = max(1, Int((box.width  * scale).rounded()))
            let pixelH = max(1, Int((box.height * scale).rounded()))

            // Render the source page to an offscreen bitmap.
            guard let bitmapCtx = CGContext(
                data: nil, width: pixelW, height: pixelH,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: bitmapInfo
            ) else { continue }
            bitmapCtx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            bitmapCtx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
            bitmapCtx.scaleBy(x: scale, y: scale)
            bitmapCtx.translateBy(x: -box.origin.x, y: -box.origin.y)
            page.draw(with: .mediaBox, to: bitmapCtx)

            guard let cgImage = bitmapCtx.makeImage() else { continue }
            // Draw the rasterized bitmap into the new PDF page at
            // PDF point coordinates. Result: a page containing one
            // image XObject and no text.
            ctx.draw(cgImage, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return outputURL
    }

    // MARK: - RTF + EPUB readers

    static func loadRTF(at path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let attr = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        return attr.string
    }

    static func extractTextFromEPUB(at url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        let chapterEntries = archive
            .filter { $0.path.hasPrefix("OEBPS/text/chapter-") && $0.path.hasSuffix(".xhtml") }
            .sorted { $0.path < $1.path }

        var collected = ""
        for entry in chapterEntries {
            var data = Data()
            _ = try archive.extract(entry, consumer: { data.append($0) })
            let xhtml = String(data: data, encoding: .utf8) ?? ""
            collected += stripHTMLTags(xhtml) + "\n"
        }
        return collected
    }

    static func stripHTMLTags(_ s: String) -> String {
        // Dump everything before <body> first — that's the head /
        // doctype / html attrs, which we don't want in the output.
        var result = s
        if let bodyStart = result.range(of: "<body>") {
            result = String(result[bodyStart.upperBound...])
        }
        if let bodyEnd = result.range(of: "</body>") {
            result = String(result[..<bodyEnd.lowerBound])
        }
        let substitutions: [(String, String)] = [
            ("<[^>]+>", " "),
            ("&amp;",  "&"),
            ("&lt;",   "<"),
            ("&gt;",   ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&nbsp;", " "),
        ]
        for (pattern, replacement) in substitutions {
            result = result.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression
            )
        }
        return result
    }

    // MARK: - CER

    /// Whitespace-normalized text. Don't lowercase or strip
    /// punctuation — case + diacritics + punctuation all matter for
    /// faithful transcription.
    static func normalize(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Standard two-row Levenshtein. Same algorithm as
    /// `OCRChangeGuardrail.levenshtein` but reimplemented here so the
    /// runner doesn't need internal Pipeline access.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        var curr = Array(repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
    }

    // MARK: - Report

    struct PrivateResult {
        let text: String
        let normChars: Int
        let editDistance: Int
        let cer: Double
        let elapsed: TimeInterval
    }

    struct CloudResult {
        let text: String
        let normChars: Int
        let editDistance: Int
        let cer: Double
        let elapsed: TimeInterval
        let claudeObservations: Int
    }

    static func makeReport(
        pdfPath: String,
        language: BCP47,
        groundTruthChars: Int,
        privateResult: PrivateResult,
        cloudResult: CloudResult?
    ) -> String {
        var out = ""
        out += "# Spike — \(language.rawValue) — \(URL(fileURLWithPath: pdfPath).lastPathComponent)\n\n"
        out += "Run \(ISO8601DateFormatter().string(from: Date())). Document: "
        out += "[\(pdfPath)](\(pdfPath)). Ground truth: "
        out += "\(groundTruthChars) normalized chars.\n\n"

        out += "## Results\n\n"
        out += "| Mode | Norm chars | Edit distance | CER | Elapsed | Claude obs |\n"
        out += "|---|---:|---:|---:|---:|---:|\n"
        out += "| `.privateLocal` "
        out += "| \(privateResult.normChars) "
        out += "| \(privateResult.editDistance) "
        out += "| \(String(format: "%.1f%%", privateResult.cer * 100)) "
        out += "| \(String(format: "%.1fs", privateResult.elapsed)) "
        out += "| — |\n"
        if let c = cloudResult {
            out += "| `.cloud` "
            out += "| \(c.normChars) "
            out += "| \(c.editDistance) "
            out += "| \(String(format: "%.1f%%", c.cer * 100)) "
            out += "| \(String(format: "%.1fs", c.elapsed)) "
            out += "| \(c.claudeObservations) |\n"

            let cerDelta = privateResult.cer - c.cer
            let direction: String
            if cerDelta > 0.005 {
                direction = "Cloud wins by \(String(format: "%.1f", cerDelta * 100)) percentage points."
            } else if cerDelta < -0.005 {
                direction = "Private wins by \(String(format: "%.1f", -cerDelta * 100)) percentage points."
            } else {
                direction = "Effectively a tie (Δ ≤ 0.5 pp)."
            }
            out += "\n**Verdict**: \(direction)\n\n"
        } else {
            out += "\n_(no `.cloud` run — API key not configured)_\n\n"
        }

        out += "## Methodology\n\n"
        out += "- CER = Levenshtein distance / ground-truth length, on whitespace-normalized text.\n"
        out += "- No lowercasing or punctuation stripping — case, diacritics, and punctuation all count as character errors.\n"
        out += "- Both modes use the same `PDFToEPUBPipeline` with the same DPI, OCR quality, and language hints; only `processingMode` + `cloudFeatures.hardRegionOCR` differ.\n"
        out += "- `.cloud` enables the Phase 3 `ClaudeOCREngine` as cascade Stage 3 (after Vision → Surya → Tesseract). Each call is guardrail-gated against the prior tier; rejected results keep the prior text.\n"
        out += "- The Claude-observation count is parsed from the debug log (`src=c` lines) — it counts emitted observations, not raw API call attempts (so guardrail rejections, refusals, and budget-exhausted skips don't show up).\n\n"

        out += "## Caveats\n\n"
        out += "- Single document, single script. A directional signal, not a verdict — extending to Hebrew + Latin scans before drawing conclusions about whole-corpus tradeoffs.\n"
        out += "- The `.cloud` Stage 3 only fires on regions the prior tiers flagged. If Vision + Tesseract did well enough on this document, Cloud's advantage will be small here even if it's large on harder material.\n"
        out += "- The pipeline produces an EPUB, then we strip HTML to compare text. Whitespace + paragraph break differences can inflate CER by a few characters per region — both modes pay the same penalty.\n"

        return out
    }

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(
            Data("[\(timestamp)] \(message)\n".utf8)
        )
    }
}
