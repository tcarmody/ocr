import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Document

/// Tesseract-backed OCR via the `tesseract` CLI binary.
///
/// **Phase 3 interim implementation.** Phase 3.5 will replace this with
/// a vendored libtesseract.dylib + Swift wrapper around the C API to
/// remove per-page Process spawn overhead (~80–150 ms) and let us
/// distribute the app self-contained. The engine surface stays
/// identical so the swap is transparent to callers.
///
/// **Pipeline.** Per call: render the input CGImage to a temp PNG,
/// invoke `tesseract <png> <output> -l <lang> tsv`, parse the resulting
/// TSV output into per-line `TextObservation`s by grouping word-level
/// rows by `(block, par, line)` key. Coordinates are converted from
/// Tesseract's pixel/top-left-origin convention to Vision's normalized
/// /bottom-left-origin convention so downstream code (header-footer
/// classifier, reflow, EPUB build) treats Tesseract observations
/// identically to Vision ones.
public struct TesseractOCREngine: OCREngine {
    public let binaryPath: String

    public init(binaryPath: String) {
        self.binaryPath = binaryPath
    }

    /// Look for `tesseract` in standard install locations. Returns nil
    /// if not found — caller can fall back or surface the error.
    public static func detect() -> TesseractOCREngine? {
        let candidates = [
            "/opt/homebrew/bin/tesseract",   // Apple Silicon Homebrew
            "/usr/local/bin/tesseract",      // Intel Homebrew or manual install
            "/usr/bin/tesseract",            // System (rare on macOS)
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return TesseractOCREngine(binaryPath: path)
            }
        }
        return nil
    }

    public enum TesseractError: Error, LocalizedError {
        case pngEncodeFailed
        case spawnFailed(Error)
        case nonZeroExit(status: Int32, stderr: String)
        case missingOutputFile(URL)

        public var errorDescription: String? {
            switch self {
            case .pngEncodeFailed:               return "Could not encode page image as PNG"
            case .spawnFailed(let e):            return "Could not spawn tesseract: \(e)"
            case .nonZeroExit(let s, let err):   return "tesseract exited with status \(s): \(err)"
            case .missingOutputFile(let u):      return "tesseract produced no output at \(u.path)"
            }
        }
    }

    public func recognize(image: CGImage, hints: OCRHints) async throws -> OCRResult {
        // CLI invocation is blocking; hop off the calling actor.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OCRResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.recognizeSync(
                        image: image, hints: hints, binaryPath: binaryPath
                    )
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - synchronous core

    private static func recognizeSync(
        image: CGImage,
        hints: OCRHints,
        binaryPath: String
    ) throws -> OCRResult {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("humanist-tess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 1. Save the rendered page as PNG for tesseract to consume.
        let imageURL = tmpDir.appendingPathComponent("input.png")
        guard let dest = CGImageDestinationCreateWithURL(
            imageURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw TesseractError.pngEncodeFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw TesseractError.pngEncodeFailed
        }

        // 2. Map BCP-47 language hints to Tesseract codes; combine with `+`.
        let langCodes = hints.languages.compactMap(Self.tesseractLangCode)
        let langArg = langCodes.isEmpty ? "eng" : langCodes.joined(separator: "+")

        // 3. Invoke tesseract → TSV. (Tesseract appends `.tsv` to outputBase.)
        let outputBase = tmpDir.appendingPathComponent("output")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = [
            imageURL.path,
            outputBase.path,
            "-l", langArg,
            "tsv",
        ]
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = Pipe()  // discard stdout (tesseract writes status here)

        do {
            try proc.run()
        } catch {
            throw TesseractError.spawnFailed(error)
        }
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "<unreadable>"
            throw TesseractError.nonZeroExit(status: proc.terminationStatus, stderr: errStr)
        }

        // 4. Read + parse the TSV.
        let tsvURL = outputBase.appendingPathExtension("tsv")
        guard FileManager.default.fileExists(atPath: tsvURL.path) else {
            throw TesseractError.missingOutputFile(tsvURL)
        }
        let tsvContents = try String(contentsOf: tsvURL, encoding: .utf8)
        return parseTSV(tsvContents, imageWidth: image.width, imageHeight: image.height)
    }

    // MARK: - language mapping

    /// Map a BCP-47 tag to a Tesseract language code (3-letter ISO 639-2).
    /// Returns nil for tags Tesseract doesn't ship by default — caller
    /// can decide whether to drop the tag or fall back.
    static func tesseractLangCode(_ tag: BCP47) -> String? {
        // Strip subtags ("la-x-medieval" → "la").
        let primary = tag.rawValue.split(separator: "-", maxSplits: 1).first.map(String.init)
            ?? tag.rawValue

        switch primary {
        // Modern Latin-script.
        case "en":   return "eng"
        case "fr":   return "fra"
        case "de":   return "deu"
        case "it":   return "ita"
        case "es":   return "spa"
        case "pt":   return "por"
        case "nl":   return "nld"
        case "pl":   return "pol"
        case "tr":   return "tur"
        case "sv":   return "swe"
        case "no":   return "nor"
        case "da":   return "dan"
        case "fi":   return "fin"
        case "ro":   return "ron"
        case "cs":   return "ces"
        case "hu":   return "hun"
        // Day-1 ancient languages from the plan.
        case "grc":  return "grc"
        case "la":   return "lat"
        // Right-to-left.
        case "he":   return "heb"
        case "ar":   return "ara"
        // Other ancient / less-common scripts shipped by tesseract-lang.
        case "syr":  return "syr"
        case "cop":  return "cop"
        case "san":  return "san"
        case "chu":  return "chu"      // Old Church Slavonic
        // CJK.
        case "zh":   return "chi_sim"
        case "ja":   return "jpn"
        case "ko":   return "kor"
        // Cyrillic.
        case "ru":   return "rus"
        case "uk":   return "ukr"
        // Pass through anything else verbatim — Tesseract will error if
        // the traineddata isn't installed and we'll surface that.
        default:     return primary
        }
    }

    // MARK: - TSV parsing

    /// Parse Tesseract TSV output. Word-level rows (level=5) are
    /// grouped by `(block, par, line)`; the matching line-level row
    /// (level=4) supplies the bbox; word texts are joined with single
    /// spaces in word-number order.
    static func parseTSV(_ tsv: String, imageWidth: Int, imageHeight: Int) -> OCRResult {
        struct Row {
            let level: Int
            let block: Int, par: Int, line: Int, word: Int
            let left: Int, top: Int, width: Int, height: Int
            let conf: Double  // 0–100 from tesseract; -1 = no confidence
            let text: String
        }
        struct LineKey: Hashable { let block: Int; let par: Int; let line: Int }

        var rows: [Row] = []
        for raw in tsv.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
            // The trailing `text` column itself can contain whitespace
            // — but TSV uses TAB as the field separator, so splitting on
            // tab is safe.
            let f = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 11,
                  let level  = Int(f[0]),
                  let block  = Int(f[2]),
                  let par    = Int(f[3]),
                  let line   = Int(f[4]),
                  let word   = Int(f[5]),
                  let left   = Int(f[6]),
                  let top    = Int(f[7]),
                  let width  = Int(f[8]),
                  let height = Int(f[9])
            else { continue }
            let conf = Double(f[10]) ?? -1
            let text = f.count >= 12 ? String(f[11]) : ""
            rows.append(Row(
                level: level, block: block, par: par, line: line, word: word,
                left: left, top: top, width: width, height: height,
                conf: conf, text: text
            ))
        }

        // Group word-level rows by line key.
        var wordsByLine: [LineKey: [Row]] = [:]
        for row in rows where row.level == 5 && !row.text.isEmpty {
            let key = LineKey(block: row.block, par: row.par, line: row.line)
            wordsByLine[key, default: []].append(row)
        }
        // Also collect line-level bboxes for bbox preference.
        var lineRows: [LineKey: Row] = [:]
        for row in rows where row.level == 4 {
            lineRows[LineKey(block: row.block, par: row.par, line: row.line)] = row
        }

        guard imageWidth > 0, imageHeight > 0 else {
            return OCRResult(text: "", meanConfidence: .nan, observations: [])
        }
        let imgW = CGFloat(imageWidth)
        let imgH = CGFloat(imageHeight)

        var observations: [TextObservation] = []
        for (key, words) in wordsByLine {
            let sortedWords = words.sorted { $0.word < $1.word }
            let text = sortedWords.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            // Prefer the line-level bbox — Tesseract computes it from
            // the actual layout. Fall back to a union of word bboxes.
            let bbox: CGRect
            if let lineRow = lineRows[key] {
                bbox = CGRect(x: lineRow.left, y: lineRow.top,
                              width: lineRow.width, height: lineRow.height)
            } else {
                let minX = sortedWords.map(\.left).min() ?? 0
                let minY = sortedWords.map(\.top).min() ?? 0
                let maxX = sortedWords.map { $0.left + $0.width }.max() ?? 0
                let maxY = sortedWords.map { $0.top + $0.height }.max() ?? 0
                bbox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }

            // Pixel/top-left → normalized/bottom-left (Vision convention).
            let nx = bbox.minX / imgW
            let nw = bbox.width / imgW
            let nh = bbox.height / imgH
            let ny = 1 - (bbox.minY + bbox.height) / imgH

            // Mean per-word confidence; tesseract reports 0–100.
            let valid = sortedWords.filter { $0.conf >= 0 }
            let meanConf = valid.isEmpty
                ? 0
                : valid.map { $0.conf / 100.0 }.reduce(0, +) / Double(valid.count)

            observations.append(TextObservation(
                text: text,
                confidence: meanConf,
                box: CGRect(x: nx, y: ny, width: nw, height: nh),
                source: .tesseract
            ))
        }

        // Predictable order: top to bottom, then left to right.
        observations.sort { a, b in
            if abs(a.box.midY - b.box.midY) > 0.005 { return a.box.midY > b.box.midY }
            return a.box.minX < b.box.minX
        }

        let mean: Double
        if observations.isEmpty {
            mean = .nan
        } else {
            mean = observations.map(\.confidence).reduce(0, +) / Double(observations.count)
        }
        let text = observations.map(\.text).joined(separator: "\n")
        return OCRResult(text: text, meanConfidence: mean, observations: observations)
    }
}
