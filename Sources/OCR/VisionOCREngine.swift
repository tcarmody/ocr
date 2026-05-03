import Foundation
import CoreGraphics
import Vision

/// Apple Vision-backed OCR. Best for modern Latin-script languages.
/// Phase 3 introduces a Tesseract sibling for ancient/non-Latin scripts.
public struct VisionOCREngine: OCREngine {
    public init() {}

    public func recognize(image: CGImage, hints: OCRHints) async throws -> OCRResult {
        // Vision's perform() is synchronous and CPU/Neural-Engine-bound;
        // hop to a global queue so we don't pin our caller's executor.
        // Continuation form rather than Task.detached because CGImage isn't
        // Sendable under Swift strict concurrency.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OCRResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.recognizeSync(image: image, hints: hints)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func recognizeSync(image: CGImage, hints: OCRHints) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = (hints.quality == .accurate) ? .accurate : .fast
        request.usesLanguageCorrection = true
        request.recognitionLanguages = hints.languages.map(\.rawValue)

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
}
