import Foundation
import OCR
import Layout

/// One of the three OCR engines the user can target with the
/// "Re-OCR Selection With…" command. Wraps engine instantiation and
/// availability detection so the menu/UI doesn't need to import the
/// individual engine modules.
enum ReOCREngineKind: String, CaseIterable, Identifiable {
    case vision, surya, tesseract

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vision:    return "Apple Vision"
        case .surya:     return "Surya"
        case .tesseract: return "Tesseract"
        }
    }

    /// `true` when the engine is installed / usable on this machine.
    /// Vision is always present (system framework); Surya needs the
    /// uv-installed sidecar; Tesseract needs the Homebrew library +
    /// tessdata.
    var isAvailable: Bool {
        switch self {
        case .vision:    return true
        case .surya:     return SuryaConnection.detect() != nil
        case .tesseract: return TesseractOCREngine.detect() != nil
        }
    }

    /// Build a fresh engine instance. Returns nil when the engine
    /// isn't installed (caller should pre-check `isAvailable`).
    func makeEngine() -> (any OCREngine)? {
        switch self {
        case .vision:
            return VisionOCREngine()
        case .surya:
            guard let conn = SuryaConnection.detect() else { return nil }
            return SuryaOCREngine(connection: conn)
        case .tesseract:
            return TesseractOCREngine.detect()
        }
    }
}
