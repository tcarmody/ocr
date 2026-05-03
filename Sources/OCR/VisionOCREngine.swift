import Foundation
import CoreGraphics
import Vision

/// Apple Vision-backed OCR. Best for modern Latin-script languages.
/// Phase 3 introduces a Tesseract sibling for ancient/non-Latin scripts.
///
/// **Two-pass strategy.** A single Vision pass reliably misses isolated
/// short lines (e.g. one-word paragraphs at the end of a column) when
/// `usesLanguageCorrection` is on — the language model rejects fragments
/// it can't fit into a sentence and discards the whole observation. We
/// run a second pass with language correction disabled and language
/// auto-detection on, then merge any pass-2 observations that don't
/// vertically overlap a pass-1 observation. Pass-1 stays authoritative
/// (it benefits from the language model on long lines); pass-2 is a
/// gap-filler.
public struct VisionOCREngine: OCREngine {
    public init() {}

    public func recognize(image: CGImage, hints: OCRHints) async throws -> OCRResult {
        async let pass1 = recognizeOnePass(
            image: image, hints: hints,
            usesLanguageCorrection: true,
            automaticallyDetectsLanguage: false
        )
        async let pass2 = recognizeOnePass(
            image: image, hints: hints,
            usesLanguageCorrection: false,
            automaticallyDetectsLanguage: true
        )

        let primary = try await pass1
        let secondary = try await pass2

        var merged = primary.observations
        for obs in secondary.observations {
            if !Self.overlapsAnyVertically(obs, in: merged, threshold: 0.5) {
                merged.append(obs)
            }
        }

        let mean: Double
        if merged.isEmpty {
            mean = .nan
        } else {
            mean = merged.map(\.confidence).reduce(0, +) / Double(merged.count)
        }
        let text = merged.map(\.text).joined(separator: "\n")
        return OCRResult(text: text, meanConfidence: mean, observations: merged)
    }

    // MARK: - one pass

    private func recognizeOnePass(
        image: CGImage,
        hints: OCRHints,
        usesLanguageCorrection: Bool,
        automaticallyDetectsLanguage: Bool
    ) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OCRResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.recognizeSync(
                        image: image, hints: hints,
                        usesLanguageCorrection: usesLanguageCorrection,
                        automaticallyDetectsLanguage: automaticallyDetectsLanguage
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func recognizeSync(
        image: CGImage,
        hints: OCRHints,
        usesLanguageCorrection: Bool,
        automaticallyDetectsLanguage: Bool
    ) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = (hints.quality == .accurate) ? .accurate : .fast
        request.usesLanguageCorrection = usesLanguageCorrection
        request.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        if !automaticallyDetectsLanguage {
            request.recognitionLanguages = hints.languages.map(\.rawValue)
        }

        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])

        let observations = (request.results ?? [])
        var collected: [TextObservation] = []
        collected.reserveCapacity(observations.count)
        var confidenceSum: Double = 0

        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let conf = Double(candidate.confidence)
            confidenceSum += conf
            collected.append(
                TextObservation(text: candidate.string, confidence: conf, box: obs.boundingBox)
            )
        }

        let mean = collected.isEmpty ? .nan : confidenceSum / Double(collected.count)
        let text = collected.map(\.text).joined(separator: "\n")
        return OCRResult(text: text, meanConfidence: mean, observations: collected)
    }

    // MARK: - merge helpers

    /// True if `candidate` vertically overlaps any observation in
    /// `existing` by at least `threshold × min-height`. Used to decide
    /// whether a permissive-pass observation is "new" or already covered
    /// by the strict pass.
    static func overlapsAnyVertically(
        _ candidate: TextObservation,
        in existing: [TextObservation],
        threshold: CGFloat
    ) -> Bool {
        for obs in existing {
            let overlap = min(candidate.box.maxY, obs.box.maxY) - max(candidate.box.minY, obs.box.minY)
            let minH = min(candidate.box.height, obs.box.height)
            guard minH > 0 else { continue }
            if overlap >= threshold * minH { return true }
        }
        return false
    }
}
