import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
import CTesseract
import Document

/// Tesseract-backed OCR via libtesseract directly (Phase 3.5a).
///
/// Per recognize call: encode CGImage → PNG bytes, hand to Leptonica
/// (`pixReadMemPng`), set on the API, recognize, iterate at WORD level,
/// group by visual line via y-clustering. Output matches the previous
/// CLI implementation exactly so the rest of the pipeline is unchanged.
///
/// Phase 3.5a reads tessdata from a brew-installed location and links
/// against `/opt/homebrew/lib/libtesseract.dylib`. Phase 3.5b will
/// switch to vendored dylibs + bundled tessdata so the .app
/// distributes self-contained.
public struct TesseractOCREngine: OCREngine {
    /// Directory containing `eng.traineddata`, `grc.traineddata`, etc.
    public let dataPath: String

    public init(dataPath: String) {
        self.dataPath = dataPath
    }

    /// Look for tessdata in standard install locations. Returns nil
    /// if not found OR if the libtesseract/libleptonica dylibs failed
    /// to load (e.g. user has tessdata installed but uninstalled
    /// brew tesseract since then). Caller falls back to Vision.
    public static func detect() -> TesseractOCREngine? {
        guard runtimeAvailable else { return nil }
        // Prefer bundled tessdata when the app ships one — that's the
        // self-contained distribution case where the user has no
        // Homebrew install at all. Falls back to Homebrew locations,
        // then any system path.
        var candidates: [String] = []
        if let bundled = bundledTessdataPath() {
            candidates.append(bundled)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/share/tessdata",   // Apple Silicon Homebrew
            "/usr/local/share/tessdata",      // Intel Homebrew
            "/usr/share/tessdata",            // System (rare on macOS)
        ])
        for path in candidates {
            if FileManager.default.fileExists(atPath: "\(path)/eng.traineddata") {
                return TesseractOCREngine(dataPath: path)
            }
        }
        return nil
    }

    /// True when libtesseract / libleptonica are loaded into the
    /// process. Probed via `dlsym(RTLD_DEFAULT, ...)`. Weak-linked at
    /// build time so the binary launches when the dylibs are absent;
    /// this check is the runtime gate that keeps any code path from
    /// calling a null function pointer.
    ///
    /// Computed once at first access and cached. Loading state can't
    /// change at runtime (dyld doesn't lazy-load weak-linked dylibs
    /// after the binary has loaded), so a one-shot probe is correct.
    public static let runtimeAvailable: Bool = {
        // RTLD_DEFAULT is `-2` cast to a void*. macOS doesn't expose
        // a typed constant for it from Swift, so we construct the
        // sentinel directly. `dlsym` returns NULL if the symbol
        // isn't loaded — that's our "dylib not present" signal.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        return dlsym(rtldDefault, "TessBaseAPICreate") != nil
            && dlsym(rtldDefault, "pixReadMemPng") != nil
    }()

    /// `<App>.app/Contents/Resources/tessdata` when the .app bundles
    /// traineddata (Phase C). Nil during `swift test` / `swift run`
    /// where there's no bundle.
    private static func bundledTessdataPath() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidate = resourceURL.appendingPathComponent("tessdata")
        let engURL = candidate.appendingPathComponent("eng.traineddata")
        guard FileManager.default.fileExists(atPath: engURL.path) else {
            return nil
        }
        return candidate.path
    }

    public enum TesseractError: Error, LocalizedError {
        case pixCreateFailed
        case recognizeFailed(Int32)
        case engineInit(LibraryTesseractInstance.InitError)

        public var errorDescription: String? {
            switch self {
            case .pixCreateFailed:        return "Could not convert CGImage to Leptonica Pix"
            case .recognizeFailed(let s): return "TessBaseAPIRecognize returned \(s)"
            case .engineInit(let e):      return e.localizedDescription
            }
        }
    }

    public func recognize(image: CGImage, hints: OCRHints) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OCRResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.recognizeSync(
                        image: image, hints: hints, dataPath: dataPath
                    )
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - synchronous core

    /// One recognized word with its pixel-space bounding box and the
    /// y-cluster line index assigned during post-processing.
    private struct WordHit {
        let text: String
        let conf: Float        // 0–100 from tesseract
        let bbox: CGRect       // pixel coords, top-left origin
        let isItalic: Bool
        let isBold: Bool
        var lineIdx: Int = 0
    }

    private static func recognizeSync(
        image: CGImage,
        hints: OCRHints,
        dataPath: String
    ) throws -> OCRResult {
        let langCodes = hints.languages.compactMap(Self.tesseractLangCode)
        let langArg = langCodes.isEmpty ? "eng" : langCodes.joined(separator: "+")

        let engine: LibraryTesseractInstance
        do {
            engine = try LibraryTesseractInstance(language: langArg, dataPath: dataPath)
        } catch let e as LibraryTesseractInstance.InitError {
            throw TesseractError.engineInit(e)
        }

        guard let pix = pixFromCGImage(image) else {
            throw TesseractError.pixCreateFailed
        }
        defer { destroyPix(pix) }

        humanist_set_image_from_pix(engine.api, pix)
        let recognizeStatus = TessBaseAPIRecognize(engine.api, nil)
        guard recognizeStatus == 0 else {
            throw TesseractError.recognizeFailed(recognizeStatus)
        }

        guard let resultIter = TessBaseAPIGetIterator(engine.api) else {
            return OCRResult(text: "", meanConfidence: .nan, observations: [])
        }
        defer { TessResultIteratorDelete(resultIter) }

        var words: [WordHit] = []
        let level = RIL_WORD
        let pageIter = TessResultIteratorGetPageIterator(resultIter)
        repeat {
            var x1: Int32 = 0, y1: Int32 = 0, x2: Int32 = 0, y2: Int32 = 0
            let gotBox = TessPageIteratorBoundingBox(pageIter, level, &x1, &y1, &x2, &y2)
            guard gotBox != 0 else { continue }

            guard let cText = TessResultIteratorGetUTF8Text(resultIter, level) else { continue }
            let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
            TessDeleteText(cText)
            if text.isEmpty { continue }

            let conf = TessResultIteratorConfidence(resultIter, level)
            let bbox = CGRect(
                x: Int(x1), y: Int(y1),
                width: Int(x2 - x1), height: Int(y2 - y1)
            )

            // Per-word font attributes. The C API takes pointers
            // to BOOLs (typedef'd Int32 here); we don't care about
            // underlined/monospace/serif/smallcaps/pointsize/font_id
            // for now, but the function still requires the out
            // pointers. `_ = fontName` — the const char* is owned
            // by Tesseract; don't free it.
            var isBoldRaw: Int32 = 0
            var isItalicRaw: Int32 = 0
            var isUnderlinedRaw: Int32 = 0
            var isMonospaceRaw: Int32 = 0
            var isSerifRaw: Int32 = 0
            var isSmallcapsRaw: Int32 = 0
            var pointsize: Int32 = 0
            var fontId: Int32 = 0
            _ = TessResultIteratorWordFontAttributes(
                resultIter,
                &isBoldRaw, &isItalicRaw,
                &isUnderlinedRaw, &isMonospaceRaw,
                &isSerifRaw, &isSmallcapsRaw,
                &pointsize, &fontId
            )

            words.append(WordHit(
                text: text, conf: conf, bbox: bbox,
                isItalic: isItalicRaw != 0,
                isBold: isBoldRaw != 0
            ))
        } while TessPageIteratorNext(pageIter, level) != 0

        let lineWords = assignLineIndices(words)

        // Convert pixel coords → Vision normalized coords + emit per-line obs.
        guard image.width > 0, image.height > 0 else {
            return OCRResult(text: "", meanConfidence: .nan, observations: [])
        }
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)

        var byLine: [Int: [WordHit]] = [:]
        for w in lineWords { byLine[w.lineIdx, default: []].append(w) }

        var observations: [TextObservation] = []
        for (_, ws) in byLine {
            let sorted = ws.sorted { $0.bbox.minX < $1.bbox.minX }
            let text = sorted.map(\.text).joined(separator: " ")

            let minX = sorted.map(\.bbox.minX).min() ?? 0
            let minY = sorted.map(\.bbox.minY).min() ?? 0
            let maxX = sorted.map(\.bbox.maxX).max() ?? 0
            let maxY = sorted.map(\.bbox.maxY).max() ?? 0
            let bbox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

            let nx = bbox.minX / imgW
            let nw = bbox.width / imgW
            let nh = bbox.height / imgH
            let ny = 1 - (bbox.minY + bbox.height) / imgH

            let valid = sorted.filter { $0.conf >= 0 }
            let meanConf = valid.isEmpty
                ? 0
                : valid.map { Double($0.conf) / 100.0 }.reduce(0, +) / Double(valid.count)

            // Aggregate font attributes per line — strict consensus.
            // A whole-line italic (foreign quote, epigraph caption)
            // gets flagged; a single italicized word in the middle
            // of body text doesn't lift the entire line. Mid-line
            // emphasis is lossy at this granularity; the eventual
            // fix is per-style-span observations, but consensus
            // gives us the high-volume cases (Latin / Greek
            // interpolations, italicized epigraphs) without
            // changing the observation shape.
            let isItalicLine = sorted.allSatisfy { $0.isItalic }
            let isBoldLine = sorted.allSatisfy { $0.isBold }

            observations.append(TextObservation(
                text: text,
                confidence: meanConf,
                box: CGRect(x: nx, y: ny, width: nw, height: nh),
                source: .tesseract,
                isItalic: isItalicLine,
                isBold: isBoldLine
            ))
        }

        // Predictable order: top-to-bottom, then left-to-right.
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

    /// Cluster words into lines by y-midpoint. Tesseract's C API
    /// doesn't expose direct line-index numbers (only block/par/line
    /// "is at beginning of" predicates), so we cluster ourselves.
    /// Pixel y is top-left origin: smaller y = higher on the page.
    private static func assignLineIndices(_ words: [WordHit]) -> [WordHit] {
        guard !words.isEmpty else { return [] }
        let sorted = words.sorted { $0.bbox.minY < $1.bbox.minY }
        let medianHeight = sorted.map(\.bbox.height).sorted()[sorted.count / 2]
        let yTolerance = max(medianHeight * 0.4, 1)
        var result: [WordHit] = []
        var currentLine = 0
        var refY = sorted[0].bbox.midY
        for var w in sorted {
            if abs(w.bbox.midY - refY) > yTolerance {
                currentLine += 1
                refY = w.bbox.midY
            }
            w.lineIdx = currentLine
            result.append(w)
        }
        return result
    }

    // MARK: - language mapping

    /// Map a BCP-47 tag to a Tesseract language code (3-letter ISO 639-2).
    /// Returns nil for tags Tesseract doesn't ship by default.
    static func tesseractLangCode(_ tag: BCP47) -> String? {
        let primary = tag.rawValue.split(separator: "-", maxSplits: 1).first.map(String.init)
            ?? tag.rawValue

        switch primary {
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
        case "grc":  return "grc"
        case "la":   return "lat"
        case "he":   return "heb"
        case "ar":   return "ara"
        case "syr":  return "syr"
        case "cop":  return "cop"
        case "san":  return "san"
        case "chu":  return "chu"
        case "zh":   return "chi_sim"
        case "ja":   return "jpn"
        case "ko":   return "kor"
        case "ru":   return "rus"
        case "uk":   return "ukr"
        default:     return primary
        }
    }
}
