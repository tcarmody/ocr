#ifndef HUMANIST_CTESSERACT_SHIM_H
#define HUMANIST_CTESSERACT_SHIM_H

// Re-export the Tesseract and Leptonica C interfaces for the Swift
// wrapper to import as a single `CTesseract` module.
//
// Headers resolve via the package's swiftSettings -Xcc -I flag pointing
// at /opt/homebrew/include (Phase 3.5a — link against brew-installed
// dylibs). Phase 3.5b will replace this with a vendored
// Vendor/tesseract/ path so the .app can ship self-contained.

#include <tesseract/capi.h>
#include <leptonica/allheaders.h>

// Leptonica's `struct Pix` is rich (image data, colormap, palette,
// etc.) and Swift either chokes on it or hands back `OpaquePointer?`
// — which mostly works but means we can't construct
// `UnsafeMutablePointer<Pix>` in Swift code. Wrap the few entry points
// we actually need behind `void*` so the Swift side can stay typed
// against `UnsafeMutableRawPointer?` for the pix lifetime.
//
// `static inline` so each .swift import sees the bodies; no separate
// .c file needed.

static inline void* humanist_pix_read_png_bytes(const unsigned char* data, size_t size) {
    return (void*)pixReadMemPng(data, size);
}

static inline void humanist_pix_destroy(void* pix) {
    PIX* ptr = (PIX*)pix;
    pixDestroy(&ptr);
}

static inline void humanist_set_image_from_pix(TessBaseAPI* api, void* pix) {
    TessBaseAPISetImage2(api, (PIX*)pix);
}

#endif
