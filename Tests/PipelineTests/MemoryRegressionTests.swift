import XCTest
import Foundation
import CoreGraphics
import CoreText
import Vision
import PDFIngest

/// T-Memory-Regression. A 100 GB leak once slipped in on bulk
/// conversions: per-page PDFKit / CoreGraphics / Vision NSObject
/// temporaries piled up on the convert task's outer autorelease pool
/// for the whole run instead of draining per page. The fix wraps the
/// per-page work in `autoreleasepool` (see `PipelineCascadeLoop` /
/// `PipelinePageOCRDispatch`). Nothing automated guarded against
/// recurrence.
///
/// This probe re-runs the leak-prone per-page primitives — render a PDF
/// page to a raster, then synchronous Vision text recognition — many
/// times and asserts the host process's resident memory stays bounded.
/// It exercises the same NSObject-heavy path the pipeline pools, with no
/// dependence on real books, Surya, the network, or Claude, so it runs
/// anywhere.
///
/// Gated behind `HUMANIST_MEMORY_PROBE=1` because it's slow (Vision OCR
/// per page) — "run on demand", not on every `swift test`:
///
///     HUMANIST_MEMORY_PROBE=1 swift test --filter MemoryRegressionTests
///
/// Tunables (env): `HUMANIST_MEMORY_PROBE_ITERS` (measured iterations,
/// default 80), `HUMANIST_MEMORY_PROBE_MAX_MB` (growth ceiling MB,
/// default 300).
///
/// What it catches: leaks that survive pooling (retain cycles, static
/// caches, ever-growing buffers) in the render/OCR path. What it does
/// NOT catch: a pipeline that simply drops its `autoreleasepool` — this
/// probe pools each iteration as the pipeline does, so that case is a
/// code-review / bulk-QA concern. The `residentBytes()` helper + harness
/// are reusable for future, more targeted memory tests.
final class MemoryRegressionTests: XCTestCase {

    func test_perPageRenderAndOCR_doesNotGrowUnbounded() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HUMANIST_MEMORY_PROBE"] == "1",
            "Set HUMANIST_MEMORY_PROBE=1 to run the (slow) memory probe."
        )
        let env = ProcessInfo.processInfo.environment
        let measured = env["HUMANIST_MEMORY_PROBE_ITERS"].flatMap(Int.init) ?? 80
        let ceilingMB = env["HUMANIST_MEMORY_PROBE_MAX_MB"].flatMap(Double.init) ?? 300
        let warmup = 12

        let pdfURL = try Self.makeTextPDF()
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        let pdf = try PDFLoader().load(pdfURL)
        let renderer = PDFRenderer(dpi: 150)

        var baseline: UInt64 = 0
        var peak: UInt64 = 0
        var final: UInt64 = 0

        for i in 0 ..< (warmup + measured) {
            // Pool each iteration exactly as the pipeline's per-page
            // dispatch does — the NSObject temporaries from rendering +
            // Vision must drain here, not accumulate across pages.
            autoreleasepool {
                guard let image = try? renderer.renderPage(at: 0, of: pdf) else {
                    return
                }
                Self.recognizeTextSync(image)
            }
            let rss = Self.residentBytes()
            if i == warmup - 1 { baseline = rss }   // after caches warm
            if i >= warmup {
                peak = max(peak, rss)
                final = rss
            }
        }

        let peakGrowthMB = Double(peak &- baseline) / 1_048_576
        let finalGrowthMB = Double(final &- baseline) / 1_048_576
        print(String(
            format: "[mem-probe] baseline=%.0fMB peak=+%.1fMB final=+%.1fMB over %d iters",
            Double(baseline) / 1_048_576, peakGrowthMB, finalGrowthMB, measured
        ))
        // A real leak shows as multi-hundred-MB-to-GB monotonic growth
        // over this many pages; the ceiling leaves headroom for Metal /
        // Vision model caches and allocator fragmentation.
        XCTAssertLessThan(
            finalGrowthMB, ceilingMB,
            "resident memory grew \(finalGrowthMB) MB over \(measured) "
            + "render+OCR iterations — possible per-page leak (regression "
            + "of the autoreleasepool fix?)"
        )
    }

    // MARK: - helpers

    /// Host process resident size in bytes via `task_info`.
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    /// Synchronous Vision text recognition — mirrors the per-page OCR
    /// the pipeline runs, without the OCR module's async wrapper (so it
    /// composes with `autoreleasepool`). Results are read so Vision
    /// actually materializes them.
    private static func recognizeTextSync(_ image: CGImage) {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do {
            try handler.perform([request])
            _ = (request.results ?? []).compactMap {
                $0.topCandidates(1).first?.string
            }
        } catch {
            // A Vision failure isn't what this probe measures — ignore.
        }
    }

    /// Generate a one-page PDF with enough real text that Vision has
    /// something to recognize. CoreText draw into a CGContext PDF.
    static func makeTextPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mem-probe-\(UUID().uuidString).pdf")
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else {
            throw NSError(
                domain: "MemoryRegressionTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "PDF context failed"]
            )
        }
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 0, alpha: 1),
        ]
        var y: CGFloat = 740
        for n in 0 ..< 50 {
            let s = "Line \(n): the quick brown fox jumps over the lazy "
                + "dog — 0123456789, classical OCR regression probe."
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: s, attributes: attrs)
            )
            ctx.textPosition = CGPoint(x: 54, y: y)
            CTLineDraw(line, ctx)
            y -= 14
            if y < 40 { break }
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }
}
