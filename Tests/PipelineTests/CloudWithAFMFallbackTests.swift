import XCTest
import CoreGraphics
import Document
import OCR
@testable import Pipeline

/// Cover the four protocol-level fallback decorators. Each test uses
/// mocked primary + fallback impls so we can assert which path fired
/// without spinning up Cloud / AFM.
final class CloudWithAFMFallbackTests: XCTestCase {

    // MARK: - PostOCRProcessor

    actor MockPostProcessor: PostOCRProcessor {
        private let stubbed: ClaudePostProcessor.Result?
        private(set) var callCount = 0
        init(_ stubbed: ClaudePostProcessor.Result?) {
            self.stubbed = stubbed
        }
        func correct(
            text: String, languages: [BCP47],
            mode: ClaudePostProcessor.Mode, regionImage: CGImage?
        ) async -> ClaudePostProcessor.Result? {
            callCount += 1
            return stubbed
        }
        func calls() -> Int { callCount }
    }

    func test_postProcessor_primary_success_skips_fallback() async {
        let primary = MockPostProcessor(.init(
            corrected: "ok", modelOutput: "ok",
            accepted: true, rejectionReason: nil
        ))
        let fallback = MockPostProcessor(nil)
        let wrapped = FallbackPostOCRProcessor(
            primary: primary, fallback: fallback
        )
        let out = await wrapped.correct(
            text: "x", languages: [],
            mode: .passages, regionImage: nil
        )
        XCTAssertEqual(out?.corrected, "ok")
        let p = await primary.calls()
        let f = await fallback.calls()
        XCTAssertEqual(p, 1)
        XCTAssertEqual(f, 0)
    }

    func test_postProcessor_primary_nil_falls_back_to_AFM() async {
        let primary = MockPostProcessor(nil)
        let fallback = MockPostProcessor(.init(
            corrected: "afm-result", modelOutput: "afm-result",
            accepted: true, rejectionReason: nil
        ))
        let wrapped = FallbackPostOCRProcessor(
            primary: primary, fallback: fallback
        )
        let out = await wrapped.correct(
            text: "x", languages: [],
            mode: .passages, regionImage: nil
        )
        XCTAssertEqual(out?.corrected, "afm-result")
        let p = await primary.calls()
        let f = await fallback.calls()
        XCTAssertEqual(p, 1)
        XCTAssertEqual(f, 1)
    }

    func test_postProcessor_both_nil_returns_nil() async {
        let primary = MockPostProcessor(nil)
        let fallback = MockPostProcessor(nil)
        let wrapped = FallbackPostOCRProcessor(
            primary: primary, fallback: fallback
        )
        let out = await wrapped.correct(
            text: "x", languages: [],
            mode: .passages, regionImage: nil
        )
        XCTAssertNil(out)
    }

    // MARK: - SemanticChapterClassifier

    actor MockClassifier: SemanticChapterClassifier {
        private let stubbed: String?
        private(set) var callCount = 0
        init(_ stubbed: String?) { self.stubbed = stubbed }
        func classify(chapter: Chapter) async -> String? {
            callCount += 1
            return stubbed
        }
        func calls() -> Int { callCount }
    }

    func test_classifier_primary_nil_falls_back_to_AFM() async {
        let primary = MockClassifier(nil)
        let fallback = MockClassifier("chapter")
        let wrapped = FallbackSemanticChapterClassifier(
            primary: primary, fallback: fallback
        )
        let chapter = Chapter(title: "T")
        let label = await wrapped.classify(chapter: chapter)
        XCTAssertEqual(label, "chapter")
        let f = await fallback.calls()
        XCTAssertEqual(f, 1)
    }

    func test_classifier_primary_success_skips_fallback() async {
        let primary = MockClassifier("preface")
        let fallback = MockClassifier("chapter")
        let wrapped = FallbackSemanticChapterClassifier(
            primary: primary, fallback: fallback
        )
        let chapter = Chapter(title: "T")
        let label = await wrapped.classify(chapter: chapter)
        XCTAssertEqual(label, "preface")
        let f = await fallback.calls()
        XCTAssertEqual(f, 0)
    }

    // MARK: - BookMetadataExtractor

    actor MockMetadataExtractor: BookMetadataExtractor {
        private let stubbed: ClaudeMetadataExtractor.Result?
        private(set) var callCount = 0
        init(_ stubbed: ClaudeMetadataExtractor.Result?) {
            self.stubbed = stubbed
        }
        func extract(
            frontMatterText: String
        ) async -> ClaudeMetadataExtractor.Result? {
            callCount += 1
            return stubbed
        }
        func calls() -> Int { callCount }
    }

    func test_metadata_primary_nil_falls_back_to_AFM() async {
        let primary = MockMetadataExtractor(nil)
        let fallback = MockMetadataExtractor(.init(
            title: "AFM Title", author: nil, year: nil,
            publisher: nil, isbn: nil
        ))
        let wrapped = FallbackBookMetadataExtractor(
            primary: primary, fallback: fallback
        )
        let result = await wrapped.extract(frontMatterText: "x")
        XCTAssertEqual(result?.title, "AFM Title")
        let f = await fallback.calls()
        XCTAssertEqual(f, 1)
    }

    // MARK: - BookCoherenceAnalyzer

    actor MockCoherenceAnalyzer: BookCoherenceAnalyzer {
        private let suggestions: [ClaudeCoherenceAnalyzer.Suggestion]
        private let appliedChapters: [Chapter]?
        private(set) var analyzeCalls = 0
        private(set) var applyCalls = 0
        init(
            suggestions: [ClaudeCoherenceAnalyzer.Suggestion] = [],
            appliedChapters: [Chapter]? = nil
        ) {
            self.suggestions = suggestions
            self.appliedChapters = appliedChapters
        }
        func analyze(
            chapters: [Chapter]
        ) async -> [ClaudeCoherenceAnalyzer.Suggestion] {
            analyzeCalls += 1
            return suggestions
        }
        func analyzeAndApply(chapters: [Chapter]) async -> [Chapter] {
            applyCalls += 1
            return appliedChapters ?? chapters
        }
        func counts() -> (analyze: Int, apply: Int) {
            (analyzeCalls, applyCalls)
        }
    }

    func test_coherence_primary_empty_suggestions_falls_back() async {
        let primary = MockCoherenceAnalyzer(suggestions: [])
        let fallback = MockCoherenceAnalyzer(
            suggestions: [.init(wrong: "teh", right: "the")]
        )
        let wrapped = FallbackBookCoherenceAnalyzer(
            primary: primary, fallback: fallback
        )
        let result = await wrapped.analyze(chapters: [])
        XCTAssertEqual(result.count, 1)
        let f = await fallback.counts()
        XCTAssertEqual(f.analyze, 1)
    }

    func test_coherence_primary_nonempty_skips_fallback() async {
        let primary = MockCoherenceAnalyzer(
            suggestions: [.init(wrong: "teh", right: "the")]
        )
        let fallback = MockCoherenceAnalyzer(
            suggestions: [.init(wrong: "fallback", right: "fb")]
        )
        let wrapped = FallbackBookCoherenceAnalyzer(
            primary: primary, fallback: fallback
        )
        let result = await wrapped.analyze(chapters: [])
        XCTAssertEqual(result.first?.wrong, "teh")
        let f = await fallback.counts()
        XCTAssertEqual(f.analyze, 0)
    }
}
