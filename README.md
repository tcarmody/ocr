# Humanist

Native macOS app that converts PDFs (born-digital, scanned, or mixed) into well-formatted EPUB 3 files. Apple Vision + Tesseract hybrid OCR, with first-class support for polytonic Greek and Latin and an extensible language pipeline for Hebrew, Syriac, Coptic, Sanskrit, etc.

Plan and architecture: `~/.claude/plans/adaptive-wiggling-lightning.md`.

## Status

Phase 1 — walking skeleton. Drag a PDF onto the window, get an EPUB out. Apple Vision OCR only, no layout analysis, no footnote detection, no Tesseract — just enough to validate the end-to-end shape and the EPUB packaging. Each subsequent phase layers a single piece of the planned pipeline on top.

## Layout

```
ocr/
├── Package.swift                       (workspace: app + library targets)
├── Sources/
│   ├── Humanist/                       (SwiftUI app target)
│   ├── Document/                       (canonical IR — Book/Chapter/Block/InlineRun)
│   ├── PDFIngest/                      (PDFKit page rendering + loading)
│   ├── OCR/                            (OCREngine protocol + VisionOCREngine)
│   ├── EPUB/                           (Book IR → EPUB 3 zipfile)
│   └── Pipeline/                       (orchestration: PDF → EPUB)
├── Tests/
│   └── EPUBTests/                      (mimetype-first-uncompressed, structure snapshots)
├── BundleAssets/
│   ├── Info.plist
│   └── Humanist.entitlements
└── Scripts/
    ├── _lib.sh                         (signing identity helper)
    ├── build-app.sh                    (swift build + assemble .app + sign)
    └── run-app.sh                      (build + open)
```

## Build and run

```sh
Scripts/build-app.sh        # builds + signs build/Humanist.app
Scripts/run-app.sh          # build + open in Finder
swift test                  # unit tests
```

Then drag a PDF onto the window. Output EPUB lands next to the source PDF (configurable later).

## Phased plan

See [adaptive-wiggling-lightning.md](file:///Users/tim/.claude/plans/adaptive-wiggling-lightning.md). Each phase ends with a `git tag`; current phase: `phase-1-skeleton`.
