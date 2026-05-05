import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Document
import Layout
import OCR
@testable import Pipeline

/// Stage 3 (Claude) of `RegionCascade.run` — only fires on regions
/// the prior tiers couldn't fix; replaces prior text only when the
/// guardrail accepts; stops when the budget signals exhaustion.
final class RegionCascadeClaudeStageTests: XCTestCase {

    // MARK: - Test scaffolding

    /// Pluggable OCREngine. Each call pops one canned response off
    /// the queue. `budgetExhaustedAfter` makes call N+1 throw the
    /// budget-exhausted error (where N is the value).
    actor StubEngine: OCREngine {
        struct Step {
            var text: String
            var throwBudgetExhausted: Bool = false
        }
        private var steps: [Step]
        private(set) var calls = 0

        init(steps: [Step]) {
            self.steps = steps
        }

        func recognize(image: CGImage, hints: OCRHints) async throws -> OCRResult {
            calls += 1
            guard !steps.isEmpty else {
                return OCRResult(text: "", meanConfidence: .nan, observations: [])
            }
            let step = steps.removeFirst()
            if step.throwBudgetExhausted {
                throw ClaudeOCREngine.ClaudeOCRError.budgetExhausted
            }
            let obs = TextObservation(
                text: step.text,
                confidence: 0.95,
                box: CGRect(x: 0, y: 0, width: 1, height: 1),
                source: .claude
            )
            return OCRResult(text: step.text, meanConfidence: 0.95, observations: [obs])
        }
    }

    private func whitePageImage(width: Int = 800, height: Int = 1000) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: info
        )!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func region(_ kind: LayoutRegion.Kind, _ box: CGRect, _ ord: Int = 0) -> LayoutRegion {
        LayoutRegion(kind: kind, box: box, readingOrder: ord, confidence: 1.0)
    }

    private func obs(_ text: String, _ box: CGRect, conf: Double = 1.0,
                     source: ObservationSource = .vision) -> TextObservation {
        TextObservation(text: text, confidence: conf, box: box, source: source)
    }

    /// Build a Vision-set with at least one region the cascade flags
    /// as problematic — single low-confidence observation in the
    /// region trips `meanConfidenceFloor` (0.85).
    private func makeProblematic(
        regionBox: CGRect = CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.4)
    ) -> (regions: [LayoutRegion], observations: [TextObservation]) {
        let r = region(.text, regionBox, 0)
        let o = obs(
            "garbled text",
            CGRect(x: 0.15, y: 0.6, width: 0.7, height: 0.05),
            conf: 0.40, source: .vision
        )
        return ([r], [o])
    }

    // MARK: - Tests

    func test_clean_observations_skip_claude_entirely() async {
        let r = region(.text, CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.4), 0)
        // High confidence + decent text → not problematic.
        let o = obs(
            "The quick brown fox jumps over the lazy dog.",
            CGRect(x: 0.15, y: 0.6, width: 0.7, height: 0.05),
            conf: 0.99
        )
        let claude = StubEngine(steps: [.init(text: "should never be called")])
        _ = await RegionCascade.run(
            observations: [o], regions: [r],
            pageImage: whitePageImage(), hints: OCRHints(),
            suryaEngine: nil, tesseractEngine: nil, claudeEngine: claude
        )
        let calls = await claude.calls
        XCTAssertEqual(calls, 0,
                       "Claude shouldn't fire on regions that aren't problematic")
    }

    func test_problematic_region_replaces_with_claude_when_guardrail_accepts() async {
        let (regions, observations) = makeProblematic()
        // Candidate is a faithful correction (similar length + same script).
        let claude = StubEngine(steps: [.init(text: "garbled text — corrected")])
        let result = await RegionCascade.run(
            observations: observations, regions: regions,
            pageImage: whitePageImage(), hints: OCRHints(),
            suryaEngine: nil, tesseractEngine: nil, claudeEngine: claude
        )
        let calls = await claude.calls
        XCTAssertEqual(calls, 1)
        // The Claude observation should be present, attributed as
        // .claude, with text matching the candidate.
        let claudeObs = result.filter { $0.source == .claude }
        XCTAssertEqual(claudeObs.count, 1)
    }

    func test_guardrail_rejection_keeps_prior_text() async {
        // Make the prior text long enough to trigger the
        // edit-distance guardrail (above the priorMinLengthForGuardrail
        // floor of 30 chars). Pure Greek so the script-drift check
        // fires cleanly when the candidate translates to Latin.
        let r = region(.text, CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.4), 0)
        let priorText = "δικαιοσύνη καὶ ἀλήθεια ἐν τῇ πόλει τῶν Ἀθηνῶν περὶ νόμου."
        let o = obs(
            priorText,
            CGRect(x: 0.15, y: 0.6, width: 0.7, height: 0.05),
            conf: 0.40
        )
        // Candidate: a translation. Pure Latin → script drift from
        // the Greek prior triggers the guardrail.
        let claude = StubEngine(steps: [.init(
            text: "justice and truth in the city of the Athenians about law."
        )])
        let result = await RegionCascade.run(
            observations: [o], regions: [r],
            pageImage: whitePageImage(), hints: OCRHints(),
            suryaEngine: nil, tesseractEngine: nil, claudeEngine: claude
        )
        let calls = await claude.calls
        XCTAssertEqual(calls, 1, "Claude was invoked")
        // The prior observation survives unchanged — no Claude
        // observation made it into the result.
        let claudeObs = result.filter { $0.source == .claude }
        XCTAssertTrue(claudeObs.isEmpty,
                      "Guardrail-rejected Claude output must not be merged")
        let visionObs = result.filter { $0.source == .vision }
        XCTAssertEqual(visionObs.count, 1)
    }

    func test_budget_exhausted_breaks_the_loop_for_this_page() async {
        // Three problematic regions; engine grants the first call
        // and throws budgetExhausted on the second.
        let regions: [LayoutRegion] = (0..<3).map { i in
            region(.text, CGRect(x: 0.1, y: 0.7 - Double(i) * 0.2,
                                 width: 0.8, height: 0.15), i)
        }
        let observations: [TextObservation] = (0..<3).map { i in
            obs(
                "garbled \(i)",
                CGRect(x: 0.15, y: 0.71 - Double(i) * 0.2,
                       width: 0.7, height: 0.04),
                conf: 0.40
            )
        }
        let claude = StubEngine(steps: [
            .init(text: "garbled 0 — corrected"),
            .init(text: "", throwBudgetExhausted: true),
        ])
        _ = await RegionCascade.run(
            observations: observations, regions: regions,
            pageImage: whitePageImage(), hints: OCRHints(),
            suryaEngine: nil, tesseractEngine: nil, claudeEngine: claude
        )
        let calls = await claude.calls
        // First call succeeded, second threw budgetExhausted, loop
        // broke before the third region was attempted.
        XCTAssertEqual(calls, 2,
                       "Loop should break on budgetExhausted, not try region 3")
    }

    func test_nil_claude_engine_acts_like_private_mode() async {
        let (regions, observations) = makeProblematic()
        let result = await RegionCascade.run(
            observations: observations, regions: regions,
            pageImage: whitePageImage(), hints: OCRHints(),
            suryaEngine: nil, tesseractEngine: nil, claudeEngine: nil
        )
        // No claude observations, prior survives.
        let claudeObs = result.filter { $0.source == .claude }
        XCTAssertTrue(claudeObs.isEmpty)
    }
}
