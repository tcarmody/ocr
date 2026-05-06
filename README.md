# Humanist

Native macOS app that converts PDFs (born-digital, scanned, or mixed) into well-formatted EPUB 3 files. Aimed at academic books — polytonic Greek, Latin, mixed-script footnotes, printed tables of contents, figures with captions. Surya for layout, Apple Vision + Tesseract for OCR, and optional Claude (Anthropic API) for the cases the local cascade can't fix on its own.

## What it does

Drop a PDF (or a folder of PDFs) onto the launcher window. Each becomes a queued job that runs through:

- **Two-up scan detection** — facing-page scans get auto-split before OCR (with a confirmation prompt).
- **Language auto-detect** — `NLLanguageRecognizer` samples three body pages and overrides the picker default when confident.
- **Pre-flight cost estimate** — Cloud-mode runs show projected Claude calls + dollar cost in the queue row before you click Convert.
- **Embedded-text trust scoring** — clean PDF text layers are passed through untouched; gibberish layers (broken `ToUnicode`, mojibake, language mismatch) trigger full re-OCR.
- **Per-region OCR cascade** — Vision → Surya → Tesseract → optional Claude (Sonnet vision) for hard regions, gated on a per-region quality scorer.
- **Layout-aware reflow** — Surya regions classify as text / heading / footnote / figure / table / caption; reflow respects the classification, splits regions at internal gaps, and reclassifies misidentified footnotes.
- **Figure + table extraction** — `.picture` regions raster-cropped into `OEBPS/images/`; `.table` regions through Surya's `TableRecPredictor` with an X/Y heuristic fallback.
- **Footnote linking** — EPUB 3 popup notes (`<aside epub:type="footnote">` + `<a epub:type="noteref">`) so readers pop them up in place.
- **Optional Claude post-OCR cleanup** — Haiku 4.5 fixes character-level errors (ligatures, missing diacritics, long-s) on regions whose quality score is below the trigger floor. Vision-mode option for the hardest cases.
- **Optional printed-TOC parsing** — one Haiku call extracts the printed table of contents into authoritative chapter titles + nav.xhtml entries.
- **Optional semantic chapter classification** — one Haiku call per chapter labels each section (`preface`, `chapter`, `appendix`, `bibliography`, `index`, etc.) for EPUB-reader semantic navigation.
- **Side-by-side editor** — every produced EPUB opens in a 3-pane editor: PDF source, XHTML markup (CodeMirror), live preview. Includes a re-OCR-current-page command and a correction-trail panel for reviewing / reverting Haiku's character cleanup.

## Privacy posture

**Private mode is the default.** Everything runs locally — Vision, Surya, Tesseract — and no data leaves your machine. Cloud features only run when you explicitly enable them in Settings (⌘,) and provide an Anthropic API key. Per-feature toggles let you opt in to specific Cloud features one at a time, and a per-book call cap bounds the cost of any single conversion.

## Build and run

```sh
Scripts/run-app.sh          # release build + assemble + sign + open
swift test                  # unit tests
```

`Scripts/run-app.sh` is the only supported launch path — `swift run` produces a bare binary without the bundled `Resources/` directory, which means the editor's CodeMirror pane and the Surya layout sidecar can't load. Always go through the script.

### Cloud-mode setup (optional)

1. Get an Anthropic API key from <https://console.anthropic.com>.
2. In Humanist, **Settings → AI → Anthropic API Key** and paste the key. It's stored in the macOS Keychain.
3. Switch **Processing Mode** to Cloud and toggle the per-feature switches you want (hard-region OCR / table extraction / post-OCR cleanup / TOC parsing / semantic classification).
4. Drop a PDF. The queue row will show a pre-flight cost estimate before the conversion starts.

Costs are typically pennies to dollars per book; the per-book call cap (default 200) clamps the worst case.

## Layout

```
ocr/
├── Package.swift
├── Sources/
│   ├── Humanist/                       (SwiftUI app target — launcher, editor, settings)
│   ├── Document/                       (canonical IR — Book / Chapter / Block / InlineRun)
│   ├── PDFIngest/                      (PDFKit rendering, embedded-text scoring, two-up detection, language profiler)
│   ├── OCR/                            (OCREngine protocol — Vision, Tesseract, embedded-text gap-filler)
│   ├── Layout/                         (Surya sidecar + region classification)
│   ├── Pipeline/                       (orchestration: PDF → cascade → reflow → chapters → EPUB)
│   ├── EPUB/                           (Book IR → EPUB 3 zipfile, XHTML / nav / OPF writers)
│   └── AI/                             (Anthropic API client, models, settings, key store)
├── Tests/                              (~380 tests across the modules above)
├── Resources/
│   └── codemirror/                     (vendored CodeMirror 5 for the editor's source pane)
├── Sidecars/
│   └── layout/sidecar.py               (Surya layout + table model, Python via uv)
├── BundleAssets/
│   ├── Info.plist
│   └── Humanist.entitlements
└── Scripts/
    ├── _lib.sh
    ├── build-app.sh                    (swift build + assemble .app + sign)
    ├── run-app.sh                      (build + open)
    └── build-icon.sh
```

### Per-EPUB sidecars

When Humanist produces an EPUB, it writes a few editor-only JSON files to `META-INF/`:

| Path | Purpose |
|---|---|
| `com.humanist.pagemap.json` | Per-page anchor → chapter file map. Drives the editor's PDF/source/preview alignment commands. |
| `com.humanist.correction-trail.json` | Per-region Haiku post-OCR cleanup decisions (accepted + guardrail-rejected). Feeds the editor's correction-trail sheet. |
| `com.humanist.parsed-toc.json` | Haiku-parsed printed TOC + inferred page offset. Surfaced in nav.xhtml entry hrefs. |

Standard EPUB readers ignore unknown META-INF files, so these round-trip through other tools cleanly.

## Plans

[PLANS.md](PLANS.md) tracks remaining work — primarily Phase 5 (Sonnet table extractor) and Phase 9 (RTL languages) plus distribution polish in Phase 10.
