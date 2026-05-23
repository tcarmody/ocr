import XCTest
import Pipeline
@testable import Humanist

/// Pin the `ConversionOptions` Codable backward-compat shims so a
/// rename doesn't silently drop a user's pref on the floor. The
/// whole-page-OCR field has been through three names; each must
/// decode to the same Bool.
final class ConversionOptionsLegacyDecodeTests: XCTestCase {

    func test_decodes_current_useWholePageOCR_key() throws {
        let json = #"""
        {"languages":["en"],"useSuryaOCR":false,"useWholePageOCR":true,"useManuscriptMode":false,"manuscriptHand":"auto","useEarlyPrintMode":false,"earlyPrintTypeface":"auto","forceOCR":false,"privateMode":false,"emitDebugLog":false,"emitSiblingTextOutputs":true,"emitSiblingDocuments":false,"forceOCRPageRangesString":"","outputSuffix":"","emitSearchablePDF":false,"bypassDedupe":false,"forceBilingualFacingPage":false,"useBatchAPI":false}
        """#.data(using: .utf8)!
        let opts = try JSONDecoder().decode(ConversionOptions.self, from: json)
        XCTAssertTrue(opts.useWholePageOCR)
    }

    func test_decodes_legacy_useClaudePageOCR_key() throws {
        // Persisted between 2024 and 2026-05-22, when the canonical
        // field name was `useClaudePageOCR`. Existing queue.json
        // blobs from that window must still load.
        let json = #"""
        {"languages":["en"],"useSuryaOCR":false,"useClaudePageOCR":true,"useManuscriptMode":false,"manuscriptHand":"auto","useEarlyPrintMode":false,"earlyPrintTypeface":"auto","forceOCR":false,"privateMode":false,"emitDebugLog":false,"emitSiblingTextOutputs":true,"emitSiblingDocuments":false,"forceOCRPageRangesString":"","outputSuffix":"","emitSearchablePDF":false,"bypassDedupe":false,"forceBilingualFacingPage":false,"useBatchAPI":false}
        """#.data(using: .utf8)!
        let opts = try JSONDecoder().decode(ConversionOptions.self, from: json)
        XCTAssertTrue(opts.useWholePageOCR)
    }

    func test_decodes_oldest_useCloudEnhancedOCR_key() throws {
        // Original name, persisted before the 2024 rename. Kept
        // working through every subsequent rename.
        let json = #"""
        {"languages":["en"],"useSuryaOCR":false,"useCloudEnhancedOCR":true,"useManuscriptMode":false,"manuscriptHand":"auto","useEarlyPrintMode":false,"earlyPrintTypeface":"auto","forceOCR":false,"privateMode":false,"emitDebugLog":false,"emitSiblingTextOutputs":true,"emitSiblingDocuments":false,"forceOCRPageRangesString":"","outputSuffix":"","emitSearchablePDF":false,"bypassDedupe":false,"forceBilingualFacingPage":false,"useBatchAPI":false}
        """#.data(using: .utf8)!
        let opts = try JSONDecoder().decode(ConversionOptions.self, from: json)
        XCTAssertTrue(opts.useWholePageOCR)
    }

    func test_current_key_wins_over_legacy_aliases() throws {
        // When both the current and a legacy key are present
        // (corruption / unusual blob shape), the current key wins.
        let json = #"""
        {"languages":["en"],"useSuryaOCR":false,"useWholePageOCR":false,"useClaudePageOCR":true,"useCloudEnhancedOCR":true,"useManuscriptMode":false,"manuscriptHand":"auto","useEarlyPrintMode":false,"earlyPrintTypeface":"auto","forceOCR":false,"privateMode":false,"emitDebugLog":false,"emitSiblingTextOutputs":true,"emitSiblingDocuments":false,"forceOCRPageRangesString":"","outputSuffix":"","emitSearchablePDF":false,"bypassDedupe":false,"forceBilingualFacingPage":false,"useBatchAPI":false}
        """#.data(using: .utf8)!
        let opts = try JSONDecoder().decode(ConversionOptions.self, from: json)
        XCTAssertFalse(opts.useWholePageOCR)
    }

    func test_encode_uses_current_key_only() throws {
        // Encoded blobs use only the current key — no `useClaudePageOCR`
        // or `useCloudEnhancedOCR` aliases get written.
        var opts = ConversionOptions()
        opts.useWholePageOCR = true
        let data = try JSONEncoder().encode(opts)
        let str = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("useWholePageOCR"))
        XCTAssertFalse(str.contains("useClaudePageOCR"))
        XCTAssertFalse(str.contains("useCloudEnhancedOCR"))
    }
}
