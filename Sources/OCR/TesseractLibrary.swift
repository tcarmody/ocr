import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CTesseract

/// Thin Swift wrapper around the libtesseract / libleptonica C APIs.
/// Owns one `TessBaseAPI*` instance and the lifecycle around it
/// (init, recognize, end/delete). NOT thread-safe — `TessBaseAPI` is
/// not re-entrant; callers must serialize access to a single instance.
/// In practice we wrap the engine in an actor (see `LibraryTesseract`).
///
/// The recognition flow per page:
///   1. Encode the input CGImage as PNG bytes in memory.
///   2. Hand those bytes to Leptonica via `pixReadMemPng` to build a
///      `Pix*` (Leptonica's image type).
///   3. `TessBaseAPISetImage2` + `TessBaseAPIRecognize`.
///   4. Iterate the result iterator at WORD level for text/box/conf.
///   5. Group words into lines by Tesseract's (block, par, line)
///      indices via `TessPageIteratorBlockType`/etc — done by the
///      caller for symmetry with the CLI parser.
///
/// Lifetime: `instance` ivar holds the API pointer; `deinit` calls
/// End + Delete. Pix is created and destroyed per recognize call.
public final class LibraryTesseractInstance {
    /// `TessBaseAPI*` from libtesseract. Internal so the engine in
    /// the sibling file can call into the C API directly without
    /// re-wrapping every entry point here.
    let api: OpaquePointer
    /// Tesseract language string used at init ("eng+grc" etc.).
    public let language: String

    public enum InitError: Error, LocalizedError {
        case createFailed
        case initFailed(language: String, dataPath: String, status: Int32)

        public var errorDescription: String? {
            switch self {
            case .createFailed:
                return "TessBaseAPICreate returned NULL"
            case .initFailed(let lang, let path, let status):
                return "TessBaseAPIInit3 failed for language=\(lang) datapath=\(path) (status=\(status))"
            }
        }
    }

    public init(language: String, dataPath: String) throws {
        guard let api = TessBaseAPICreate() else {
            throw InitError.createFailed
        }
        let status = TessBaseAPIInit3(api, dataPath, language)
        guard status == 0 else {
            TessBaseAPIDelete(api)
            throw InitError.initFailed(language: language, dataPath: dataPath, status: status)
        }
        self.api = api
        self.language = language
    }

    deinit {
        TessBaseAPIEnd(api)
        TessBaseAPIDelete(api)
    }
}

/// Convert a CGImage to a Leptonica `Pix*` via PNG round-trip.
/// Returns the pix as `UnsafeMutableRawPointer` — Swift can't
/// represent the Leptonica `PIX` struct cleanly, so we keep it
/// type-erased and route image-side calls through C inline shims.
///
/// Encoding adds ~5–10 ms per page on Apple Silicon, dwarfed by
/// per-page recognition time and well under the ~80–150 ms saved by
/// avoiding a Process spawn. Raw-bytes → `pixCreate` would shave the
/// encoding cost; deferred until measured to matter.
func pixFromCGImage(_ image: CGImage) -> UnsafeMutableRawPointer? {
    guard let mutableData = CFDataCreateMutable(nil, 0) else { return nil }
    guard let dest = CGImageDestinationCreateWithData(
        mutableData, UTType.png.identifier as CFString, 1, nil
    ) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }

    let length = CFDataGetLength(mutableData)
    guard length > 0 else { return nil }
    let bytes = CFDataGetBytePtr(mutableData)!
    return bytes.withMemoryRebound(to: UInt8.self, capacity: length) { ptr in
        humanist_pix_read_png_bytes(ptr, length)
    }
}

/// Free a Pix returned by Leptonica via the C inline shim.
func destroyPix(_ pix: UnsafeMutableRawPointer) {
    humanist_pix_destroy(pix)
}
