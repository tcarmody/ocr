import Foundation
import CoreGraphics
import CoreImage

/// Cleans up a rendered page before OCR sees it. Applies a small
/// stack of Core Image filters tuned for **scanned book pages**:
/// stretching the contrast on faded scans, mild denoise on
/// grain / speckle, and a gentle unsharp mask that recovers
/// slightly-blurred glyphs.
///
/// Designed to be a no-op for born-digital PDFs — the pipeline
/// only invokes this when `DocumentProfile.isLikelyScan` is true,
/// because applying contrast / sharpening to already-crisp
/// born-digital text can clip or ring around glyph edges and
/// actively degrade Vision's output.
///
/// **Not deskew.** True deskew (rotate the page so text lines are
/// horizontal) needs Hough-transform line-angle detection or
/// `VNDetectDocumentSegmentationRequest` and isn't trivial to
/// pull off without false rotations on born-digital pages. Faded
/// / low-contrast scans benefit much more from levels + denoise +
/// sharpen than from a 1° deskew, so v1 leaves rotation alone.
/// Add later if specific scan corpora prove it pays off.
public struct PageImagePreprocessor {
    /// Stretch the histogram so dark text is darker and the page
    /// background is whiter. Driven by `CIColorControls.contrast`
    /// + `CIToneCurve` for the levels stretch. Most useful on
    /// faded photocopies / aging library scans.
    public var stretchContrast: Bool

    /// Light noise reduction via `CINoiseReduction`. Helps on
    /// scan grain and JPEG block noise that Vision otherwise
    /// segments as additional text.
    public var denoise: Bool

    /// Gentle `CIUnsharpMask` to recover slightly-blurred glyphs.
    /// Conservative defaults — too much sharpening creates ringing
    /// around glyph edges that hurts more than it helps.
    public var sharpen: Bool

    public init(
        stretchContrast: Bool = true,
        denoise: Bool = true,
        sharpen: Bool = true
    ) {
        self.stretchContrast = stretchContrast
        self.denoise = denoise
        self.sharpen = sharpen
    }

    /// Returns `image` with the configured filters applied. On any
    /// CI failure the original image is returned unchanged —
    /// preprocessing is best-effort, never blocks the conversion.
    public func process(_ image: CGImage) -> CGImage {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        var ci = CIImage(cgImage: image)

        if stretchContrast {
            // CIColorControls: bump contrast modestly, keep saturation
            // at default (1) so we don't shift hues on aging-paper
            // scans (yellowed pages keep their tint, just brighter).
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(1.15, forKey: kCIInputContrastKey)
                f.setValue(0.02, forKey: kCIInputBrightnessKey)
                if let out = f.outputImage { ci = out }
            }
        }

        if denoise {
            if let f = CIFilter(name: "CINoiseReduction") {
                f.setValue(ci, forKey: kCIInputImageKey)
                // Conservative: just enough to smooth out grain
                // without softening glyph edges.
                f.setValue(0.02, forKey: "inputNoiseLevel")
                f.setValue(0.40, forKey: "inputSharpness")
                if let out = f.outputImage { ci = out }
            }
        }

        if sharpen {
            if let f = CIFilter(name: "CIUnsharpMask") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(1.5, forKey: kCIInputRadiusKey)
                f.setValue(0.4, forKey: kCIInputIntensityKey)
                if let out = f.outputImage { ci = out }
            }
        }

        // Render back to CGImage. CI keeps the same extent we fed in
        // so dimensions are preserved unless a filter explicitly
        // grew the bounds (none of ours do).
        guard let out = context.createCGImage(ci, from: ci.extent) else {
            return image
        }
        return out
    }
}
