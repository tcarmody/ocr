import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Document
import OCR

/// `OCREngine` impl backed by Surya OCR via the shared Python sidecar.
///
/// Slower than Vision (~10–20 s/page on Apple Silicon vs ~1 s) but
/// noticeably more accurate on book scans where Vision tends to drop
/// or garble lines. Designed for "high accuracy mode" — selected
/// explicitly by the user when output quality matters more than speed.
///
/// The engine writes the input CGImage to a temp PNG and passes the
/// path to the sidecar (we're not sandboxed, so file paths are the
/// fastest IPC). Returned per-line text is wrapped as
/// `TextObservation` with `source: .surya`.
public struct SuryaOCREngine: OCREngine {
    public let connection: SuryaConnection

    /// Build an engine from auto-detected connection. Returns nil if
    /// Surya/sidecar isn't available.
    public static func detect() -> SuryaOCREngine? {
        SuryaConnection.detect().map(SuryaOCREngine.init)
    }

    public init(connection: SuryaConnection) {
        self.connection = connection
    }

    public enum SuryaOCRError: Error, LocalizedError {
        case pngEncodeFailed
        case noLines

        public var errorDescription: String? {
            switch self {
            case .pngEncodeFailed: return "Could not encode page image as PNG for Surya"
            case .noLines:         return "Surya OCR produced no text lines"
            }
        }
    }

    public func recognize(image: CGImage, hints: OCRHints) async throws -> OCRResult {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("humanist-surya-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let imageURL = tmpDir.appendingPathComponent("input.png")
        guard let dest = CGImageDestinationCreateWithURL(
            imageURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw SuryaOCRError.pngEncodeFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw SuryaOCRError.pngEncodeFailed
        }

        let pageBounds = CGSize(width: image.width, height: image.height)
        let langs = hints.languages.map(\.rawValue)
        let lines = try await connection.ocr(
            imageURL: imageURL,
            languages: langs,
            pageBounds: pageBounds
        )

        // Convert Surya lines to TextObservations in normalized
        // bottom-left coords. (Surya gives pixel/top-left.)
        let observations: [TextObservation] = lines.map { line in
            let normalized = SuryaConnection.normalize(line.bbox, in: line.imageSize)
            return TextObservation(
                text: line.text,
                confidence: line.confidence,
                box: normalized,
                source: .surya
            )
        }

        let mean: Double
        if observations.isEmpty { mean = .nan }
        else {
            mean = observations.map(\.confidence).reduce(0, +) / Double(observations.count)
        }
        let text = observations.map(\.text).joined(separator: "\n")
        return OCRResult(text: text, meanConfidence: mean, observations: observations)
    }
}
