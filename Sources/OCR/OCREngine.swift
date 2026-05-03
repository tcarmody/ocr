import Foundation
import CoreGraphics
import Document

/// Hints passed to an OCR engine. Future fields: PSM (page segmentation
/// mode for Tesseract), max length, character allowlist, etc.
public struct OCRHints: Sendable, Equatable {
    public enum Quality: Sendable, Equatable { case fast, accurate }

    /// BCP-47 language tags, ordered by preference. Vision uses these for
    /// language-corrected recognition; Tesseract uses them to pick a
    /// traineddata file.
    public var languages: [BCP47]
    public var quality: Quality

    public init(languages: [BCP47] = [.en], quality: Quality = .accurate) {
        self.languages = languages
        self.quality = quality
    }
}

/// Where a text observation came from. Vision OCR is the primary
/// source; the embedded PDF text layer fills gaps where Vision is
/// silent (see `Pipeline.EmbeddedTextGapFiller`).
public enum ObservationSource: Sendable, Equatable {
    case vision
    case embedded
}

/// One recognized text region, with location and confidence. Bounding
/// box uses Vision's normalized [0,1] coordinate system, origin at the
/// lower-left corner of the input image.
public struct TextObservation: Sendable, Equatable {
    public var text: String
    public var confidence: Double  // 0...1
    public var box: CGRect
    public var source: ObservationSource

    public init(
        text: String,
        confidence: Double,
        box: CGRect,
        source: ObservationSource = .vision
    ) {
        self.text = text
        self.confidence = confidence
        self.box = box
        self.source = source
    }
}

public struct OCRResult: Sendable, Equatable {
    /// Concatenation of all observations in reading order, joined by `\n`.
    public var text: String
    /// Mean confidence across observations. 0...1. NaN if no observations.
    public var meanConfidence: Double
    public var observations: [TextObservation]

    public init(text: String, meanConfidence: Double, observations: [TextObservation]) {
        self.text = text
        self.meanConfidence = meanConfidence
        self.observations = observations
    }
}

/// The seam every OCR engine implements. Per the plan, this is the type
/// that everything routes through — Apple Vision today, Tesseract in
/// Phase 3, transformer-OCR if needed later. Adding a new backend only
/// requires conforming to this protocol.
public protocol OCREngine: Sendable {
    func recognize(image: CGImage, hints: OCRHints) async throws -> OCRResult
}
