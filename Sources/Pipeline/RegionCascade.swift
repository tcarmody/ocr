import Foundation
import CoreGraphics
import OCR
import Layout

/// Phase 4.5 — per-region OCR cascade.
///
/// After Vision + layout analysis, evaluate each text-bearing region.
/// For regions whose Vision observations look bad — low mean confidence
/// or a vertical gap that smells like missing lines — re-OCR with the
/// next engine in the cascade:
///
///   Vision → Surya (whole-page re-OCR, region-by-region replacement)
///         → Tesseract (per-region crop + re-OCR for any region still
///           problematic after Surya)
///         → Google Document OCR (Cloud-mode only; per-region crop)
///         → Claude (Cloud-mode only; per-region crop, final tier)
///
/// Surya re-OCR is once-per-page (we render the page anyway, and Surya
/// pages are easier to feed than crops), then we project Surya lines
/// into the problematic regions. Tesseract is per-region because it's
/// fast and crops are easy. Google Document OCR (Cloud Vision API
/// DOCUMENT_TEXT_DETECTION) at $0.0015/call absorbs most of the hard
/// tail before falling through to Claude.
enum RegionCascade {

    /// Mean region confidence below this triggers re-OCR. Raised
    /// from 0.85 → 0.88 to catch more "looks fine but isn't"
    /// regions on scanned books — Vision tends to score in the
    /// high 0.8s on degraded scans where it's missing diacritics
    /// or running words together.
    static let meanConfidenceFloor: Double = 0.88
    /// Any single observation in a region with confidence below this
    /// triggers re-OCR. Catches the "Vision is confidently mostly-OK
    /// but one line is garbage" case the mean smooths over.
    /// Raised from 0.70 → 0.78 alongside the mean floor.
    static let minObservationConfidenceFloor: Double = 0.78
    /// Vertical gap between consecutive observations in a region, in
    /// units of median observation height, that triggers re-OCR. A
    /// well-set paragraph has ~zero within-region gap; gap > 1× line
    /// height ≈ at least one missing line.
    static let gapMultiplier: CGFloat = 1.0
    /// Combined OCR-text quality (single-char ratio · long-word ratio
    /// · language confidence) below this triggers re-OCR. Catches
    /// over-confident garbage that the confidence/gap floors miss —
    /// Vision sometimes returns 0.9+ on text that's run together or
    /// split apart.
    ///
    /// Raised from 0.5 → 0.65 system-wide. The previous value let
    /// regions through with sloppy single-char tokenization or
    /// missing diacritics as long as `NLLanguageRecognizer`
    /// confidence stayed high; 0.65 catches the bulk of the
    /// scanner-noise cases the user kept seeing pass through. Cost
    /// floor: more Surya / Tesseract / Sonnet calls per book.
    static let textQualityFloor: Double = 0.65
    /// How much to inflate region bboxes when matching observations
    /// (matches the value RegionAwareReflow uses).
    static let regionInflation: CGFloat = 0.005
    /// Crop margin around a region for Tesseract re-OCR (normalized).
    static let cropMargin: CGFloat = 0.02

    static let textBearingKinds: Set<LayoutRegion.Kind> = [
        .text, .sectionHeader, .title, .listItem, .caption,
    ]

    /// Run the cascade on a single page. Returns the (possibly
    /// updated) observation list. Callers pass in the page's source
    /// CGImage so we can crop it for per-region Tesseract calls.
    ///
    /// `claudeEngine` is the Cloud-mode-only final tier — populated
    /// only when `processingMode == .cloud` AND
    /// `cloudFeatures.hardRegionOCR` is on. Nil in `.privateLocal` mode.
    ///
    /// `forceClaudeOnAllRegions` is a spike-only knob: when true,
    /// every text-bearing region is fed to Claude unconditionally,
    /// and the guardrail comparison against the prior tier is
    /// bypassed (since the comparison would just keep prior-tier
    /// text and contaminate a Claude-only CER measurement).
    /// Production code must leave this off — the cascade is
    /// designed to gate Claude behind a quality floor for cost
    /// control.
    static func run(
        observations: [TextObservation],
        regions: [LayoutRegion],
        pageImage: CGImage,
        hints: OCRHints,
        suryaEngine: (any OCREngine)?,
        tesseractEngine: (any OCREngine)?,
        documentAIEngine: (any OCREngine)? = nil,
        claudeEngine: (any OCREngine)? = nil,
        forceClaudeOnAllRegions: Bool = false
    ) async -> [TextObservation] {
        // Pre-flight: which regions are problematic?
        var problemIndices: Set<Int>
        if forceClaudeOnAllRegions, claudeEngine != nil {
            problemIndices = Set(regions.indices.filter {
                textBearingKinds.contains(regions[$0].kind)
            })
        } else {
            problemIndices = problematicRegionIndices(
                observations: observations, regions: regions
            )
        }
        if problemIndices.isEmpty { return observations }

        var result = observations

        // --- Stage 1: Surya whole-page re-OCR ---
        if !problemIndices.isEmpty, let surya = suryaEngine {
            do {
                let suryaResult = try await surya.recognize(image: pageImage, hints: hints)
                for i in problemIndices {
                    result = replace(
                        observations: result,
                        inRegion: regions[i],
                        with: filter(
                            observations: suryaResult.observations,
                            inRegion: regions[i]
                        )
                    )
                }
                problemIndices = problematicRegionIndices(
                    observations: result, regions: regions, candidates: problemIndices
                )
            } catch {
                // Surya failed; carry on with Vision results.
            }
        }

        // --- Stage 2: per-region Tesseract crops ---
        if !problemIndices.isEmpty, let tess = tesseractEngine {
            for i in problemIndices {
                let region = regions[i]
                guard let cropped = cropImage(pageImage, to: region.box) else { continue }
                do {
                    let cropResult = try await tess.recognize(image: cropped, hints: hints)
                    let translated = translate(
                        observations: cropResult.observations,
                        fromCropOf: region.box,
                        intoFullPage: pageImage
                    )
                    // Confine to the region: crop margin pulls in glyphs
                    // from neighboring regions, and without filtering
                    // those observations land outside `region.box` and
                    // get attributed to the wrong region downstream.
                    let confined = filter(observations: translated, inRegion: region)
                    result = replace(
                        observations: result, inRegion: region, with: confined
                    )
                } catch {
                    // continue with whatever we have
                }
            }
            // Re-evaluate after Tesseract so Claude only fires on
            // regions Tesseract didn't fix.
            problemIndices = problematicRegionIndices(
                observations: result, regions: regions, candidates: problemIndices
            )
        }

        // --- Stage 2.5: per-region Google Document OCR (Cloud-mode only) ---
        //
        // Cloud Vision DOCUMENT_TEXT_DETECTION at ~$0.0015/call sits
        // between Tesseract and Claude. Absorbs the bulk of the
        // hard-region tail (degraded scans, skew, low contrast) that
        // Tesseract can't read; only the genuinely difficult cases
        // (polytonic Greek, Hebrew, vertical CJK, manuscript) fall
        // through to Claude. Guardrail-gated against the prior tier
        // same as Stage 3.
        if !problemIndices.isEmpty, let docAI = documentAIEngine,
           !forceClaudeOnAllRegions {
            let stageProblems = problemIndices
            cascadeDocAILoop: for i in stageProblems {
                let region = regions[i]
                guard let cropped = cropImage(pageImage, to: region.box) else { continue }

                let priorObs = filter(observations: result, inRegion: region)
                    .sorted { $0.box.midY > $1.box.midY }
                let priorText = priorObs.map(\.text).joined(separator: " ")

                let cropResult: OCRResult
                do {
                    cropResult = try await docAI.recognize(image: cropped, hints: hints)
                } catch GoogleDocumentOCREngine.DocumentOCRError.budgetExhausted {
                    break cascadeDocAILoop
                } catch LandingAIDocumentEngine.DocumentOCRError.budgetExhausted {
                    // Same posture as the Google budget catch — the
                    // shared `ClaudeCallBudget` is exhausted, so no
                    // further per-region docAI attempts will succeed
                    // on this page.
                    break cascadeDocAILoop
                } catch {
                    continue
                }

                let candidateText = cropResult.observations.map(\.text)
                    .joined(separator: " ")
                let decision = OCRChangeGuardrail.accept(
                    prior: priorText, candidate: candidateText
                )
                guard decision.accepted else { continue }

                let translated = translate(
                    observations: cropResult.observations,
                    fromCropOf: region.box,
                    intoFullPage: pageImage
                )
                let confined = filter(observations: translated, inRegion: region)
                result = replace(
                    observations: result, inRegion: region, with: confined
                )
            }
            // Re-evaluate after Doc OCR so Claude only fires on the
            // residual tail it didn't fix.
            problemIndices = problematicRegionIndices(
                observations: result, regions: regions, candidates: problemIndices
            )
        }

        // --- Stage 3: per-region Claude crops (Cloud-mode only) ---
        //
        // Per-region cropping (not whole-page) for cost — Claude vision
        // is the most expensive tier, and we only want to spend tokens
        // on regions the local stack couldn't handle. Each call is
        // guardrail-gated: if Claude's text differs from the prior
        // tier's by more than `OCRChangeGuardrail`'s thresholds (length
        // delta, script drift, edit distance) we keep the prior text
        // rather than ship a possible hallucination.
        //
        // Budget exhaustion (per-book cap reached) is signaled by
        // `ClaudeOCREngine.ClaudeOCRError.budgetExhausted` — caught
        // here so the pipeline keeps converting on the prior tier.
        if !problemIndices.isEmpty, let claude = claudeEngine {
            cascadeClaudeLoop: for i in problemIndices {
                let region = regions[i]
                guard let cropped = cropImage(pageImage, to: region.box) else { continue }

                // Capture prior-tier text for this region — that's what
                // the guardrail compares against.
                let priorObs = filter(observations: result, inRegion: region)
                    .sorted { $0.box.midY > $1.box.midY }
                let priorText = priorObs.map(\.text).joined(separator: " ")

                let cropResult: OCRResult
                do {
                    cropResult = try await claude.recognize(image: cropped, hints: hints)
                } catch ClaudeOCREngine.ClaudeOCRError.budgetExhausted {
                    // Budget hit — don't try any more regions this
                    // page, keep the prior tier.
                    break cascadeClaudeLoop
                } catch {
                    // Network blip, refusal, decode failure — skip
                    // this region, try the next.
                    continue
                }

                // Compare candidate vs prior. Reject hallucinations.
                // Skipped under `forceClaudeOnAllRegions` — there
                // the spike is measuring Claude's absolute quality,
                // and a guardrail rejection would resurrect the
                // prior tier's text and contaminate the CER number.
                if !forceClaudeOnAllRegions {
                    let candidateText = cropResult.observations.map(\.text)
                        .joined(separator: " ")
                    let decision = OCRChangeGuardrail.accept(
                        prior: priorText, candidate: candidateText
                    )
                    guard decision.accepted else { continue }
                }

                let translated = translate(
                    observations: cropResult.observations,
                    fromCropOf: region.box,
                    intoFullPage: pageImage
                )
                let confined = filter(observations: translated, inRegion: region)
                result = replace(
                    observations: result, inRegion: region, with: confined
                )
            }
        }

        return result
    }

    // MARK: - problem detection

    /// Return the indices of regions whose Vision observations look bad.
    /// `candidates` optionally restricts the search (used to re-evaluate
    /// after a stage of the cascade ran).
    static func problematicRegionIndices(
        observations: [TextObservation],
        regions: [LayoutRegion],
        candidates: Set<Int>? = nil
    ) -> Set<Int> {
        var out = Set<Int>()
        for (i, region) in regions.enumerated() {
            if let candidates, !candidates.contains(i) { continue }
            guard textBearingKinds.contains(region.kind) else { continue }
            let inRegion = filter(observations: observations, inRegion: region)
            // Empty region: not problematic — region just has no text
            // to worry about (could be a misclassified empty region).
            guard !inRegion.isEmpty else { continue }
            if isProblematic(observations: inRegion) {
                out.insert(i)
            }
        }
        return out
    }

    static func isProblematic(observations: [TextObservation]) -> Bool {
        guard !observations.isEmpty else { return false }

        // Aggregate confidence checks.
        let confs = observations.map(\.confidence)
        let meanConf = confs.reduce(0, +) / Double(confs.count)
        if meanConf < meanConfidenceFloor { return true }
        if let minConf = confs.min(), minConf < minObservationConfidenceFloor {
            return true
        }

        // OCR-text quality check — catches over-confident gibberish
        // (words run together, words split apart, low language
        // confidence) that the confidence floors above miss because
        // Vision claimed 0.9+ on the bad output.
        let regionText = observations.map(\.text).joined(separator: " ")
        if let q = OCRTextQualityScorer().score(text: regionText),
           q.combined < textQualityFloor {
            return true
        }

        // Vertical gap check (within-region: smells like Vision dropped
        // a line or two and left us with a paragraph that reads as a
        // truncated fragment).
        let sorted = observations.sorted { $0.box.midY > $1.box.midY }  // top first
        guard sorted.count >= 2 else { return false }
        let medianH = sorted.map(\.box.height).sorted()[sorted.count / 2]
        guard medianH > 0 else { return false }
        for i in 1..<sorted.count {
            let prevBottom = sorted[i - 1].box.minY
            let currTop    = sorted[i].box.maxY
            let gap = prevBottom - currTop
            if gap > gapMultiplier * medianH { return true }
        }
        return false
    }

    // MARK: - region <-> observation operations

    static func filter(
        observations: [TextObservation], inRegion region: LayoutRegion
    ) -> [TextObservation] {
        let inflated = region.box.insetBy(dx: -regionInflation, dy: -regionInflation)
        return observations.filter { obs in
            inflated.contains(CGPoint(x: obs.box.midX, y: obs.box.midY))
        }
    }

    static func replace(
        observations: [TextObservation],
        inRegion region: LayoutRegion,
        with replacements: [TextObservation]
    ) -> [TextObservation] {
        let inflated = region.box.insetBy(dx: -regionInflation, dy: -regionInflation)
        var out = observations.filter { obs in
            !inflated.contains(CGPoint(x: obs.box.midX, y: obs.box.midY))
        }
        out.append(contentsOf: replacements)
        return out
    }

    // MARK: - cropping + coordinate translation

    /// Crop `image` to the region's normalized bbox, with `cropMargin`
    /// on each side. Returns the cropped CGImage or nil if the result
    /// would be degenerate.
    static func cropImage(_ image: CGImage, to normalizedRegionBox: CGRect) -> CGImage? {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        guard imgW > 0, imgH > 0 else { return nil }

        let inflated = normalizedRegionBox.insetBy(dx: -cropMargin, dy: -cropMargin)
        // Clamp to [0,1].
        let nx = max(0, min(1, inflated.minX))
        let ny = max(0, min(1, inflated.minY))
        let nMaxX = max(0, min(1, inflated.maxX))
        let nMaxY = max(0, min(1, inflated.maxY))
        let nw = nMaxX - nx
        let nh = nMaxY - ny
        guard nw > 0.001, nh > 0.001 else { return nil }

        // Convert normalized bottom-left to pixel top-left.
        let pixelX = nx * imgW
        let pixelY = (1 - nMaxY) * imgH
        let pixelW = nw * imgW
        let pixelH = nh * imgH
        let cropRect = CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH).integral
        return image.cropping(to: cropRect)
    }

    /// Translate observations from a CROPPED image's coordinate space
    /// back to the full page's normalized coordinate space.
    static func translate(
        observations: [TextObservation],
        fromCropOf normalizedRegionBox: CGRect,
        intoFullPage pageImage: CGImage
    ) -> [TextObservation] {
        let inflated = normalizedRegionBox.insetBy(dx: -cropMargin, dy: -cropMargin)
        let nx = max(0, min(1, inflated.minX))
        let ny = max(0, min(1, inflated.minY))
        let nMaxX = max(0, min(1, inflated.maxX))
        let nMaxY = max(0, min(1, inflated.maxY))
        let regionW = nMaxX - nx
        let regionH = nMaxY - ny
        guard regionW > 0, regionH > 0 else { return [] }

        return observations.map { obs in
            // obs.box is in normalized coords of the CROPPED image
            // (Vision/Tesseract convention: bottom-left origin, [0,1]).
            // Translate to full-page normalized.
            let fullX = nx + obs.box.minX * regionW
            let fullY = ny + obs.box.minY * regionH
            let fullW = obs.box.width * regionW
            let fullH = obs.box.height * regionH
            return TextObservation(
                text: obs.text,
                confidence: obs.confidence,
                box: CGRect(x: fullX, y: fullY, width: fullW, height: fullH),
                source: obs.source
            )
        }
    }
}
