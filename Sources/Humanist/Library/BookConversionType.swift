import Foundation

/// R-Auto-Collections. Where a library row came from — the conversion
/// path or import path that produced the EPUB. Stamped on
/// `LibraryEntry.conversionType` at write time, used by the
/// auto-collection generator to bucket books by Type
/// (Print / Manuscript / Early Print / Digital).
///
/// Phase 1 of the auto-collection feature: deterministic
/// classification from data we already have, no model required.
/// Genre classification (Phase 2) layers on top using AFM.
///
/// `Codable` via raw string so the LibraryEntry JSON stays
/// forward-compatible if new cases are added.
public enum BookConversionType: String, Sendable, Codable,
                                CaseIterable, Hashable {
    /// PDF → EPUB via the standard cascade (Vision / Surya /
    /// Tesseract / optional Claude Sonnet OCR). The default for
    /// modern printed books.
    case print

    /// PDF → EPUB via E-Vision-Modes Early Print mode (Sonnet
    /// 4.6 + normalizing-posture prompt). 15th–18th c. printed
    /// books with period orthography.
    case earlyPrint

    /// PDF → EPUB via E-Vision-Modes Manuscript mode (Opus 4.7
    /// + hand-specific prompt). Handwritten material.
    case manuscript

    /// EPUB imported directly via R-EPUB-Import — no PDF source.
    /// "Digital" in the user-facing sense: born-digital or
    /// converted-from-Word originals.
    case digital

    /// Display label for the auto-generated Type collection.
    public var displayName: String {
        switch self {
        case .print: return "Print"
        case .earlyPrint: return "Early Print"
        case .manuscript: return "Manuscript"
        case .digital: return "Digital"
        }
    }
}
