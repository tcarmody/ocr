# Humanist — Outstanding Plans

A consolidated picture of work remaining on Humanist. Read this first
in any new session — it's the canonical "where do we go from here"
document.

For deep design docs on the AI-assisted structured-document work,
see [Plans/Phase2-Semantic-Classification.md](Plans/Phase2-Semantic-Classification.md)
and [Plans/Phase3-TOC-Parsing.md](Plans/Phase3-TOC-Parsing.md). Both are
deferred for now but fully designed.

---

## Status snapshot (as of 2026-05-04)

**Done from the original 10-phase plan**:
- Phase 0: notarized python-build-standalone spike
- Phase 1: walking skeleton (drop PDF → Vision OCR → EPUB)
- Phase 2: embedded text extraction + quality scoring
- Phase 3: Tesseract integration (linked via C API, not the CLI)
- Phase 4: Surya layout sidecar + per-region cascade
- Phase 5: footnote detection + EPUB 3 popup linking
- Phase 7: bulk job queue + drag-drop folders + GRDB-free persistence
- Phase 8: side-by-side editor (PDF / source / preview, linked nav)

**Done above the original plan** (quality + robustness):
- Two-up scan detection + auto-split pipeline
- Memory hardening (per-page autoreleasepool, periodic PDF reload,
  shared Surya sidecar singleton, editor deinit)
- Header / footer reclassification (per-page heuristic + page-number
  bypass + cross-page recurrence pass)
- Footnote heuristic for `.text` regions Surya mislabeled
- Region splitting at internal gap (Surya-merged body+footnote)
- Heading reading-order correction (top-of-page headings Surya
  ordered after body)
- ChapterSplitter — flat block stream → multi-chapter Book IR

**Remaining from the original 10-phase plan**:
- Phase 6 — Figure extraction (images dropped today)
- Phase 9 — Language extensibility (RTL: Hebrew / Syriac / Coptic)
- Phase 10 — Polish + distribution (Sparkle, DMG, bundled Python)

**Deferred (designed, not built)**:
- Structured-doc Phase 2 — semantic chapter classification
- Structured-doc Phase 3 — PDF TOC parsing

---

# Tier 1: Immediate quality gaps

Things the user has either flagged or will flag the next time they
open an academic / illustrated book.

## P6 — Figure extraction

**Status**: not started. Surya emits `.picture`, `.table`, `.formula`
regions; `RegionAwareReflow.bodyKinds` filters them out and we
silently drop every image in every book.

### Goal

Extract figures from each page (vector-first, raster fallback) and
embed them in the EPUB at the correct reading position with the
correct caption.

### Approach

```
PDFIngest/FigureExtractor.swift     vector + raster extraction
Pipeline/CaptionAssociator.swift    pair `.picture` with nearby `.caption`
Pipeline/RegionAwareReflow.swift    add .figure case to Block; emit in stream
Document/Block.swift                + case figure(href, alt, caption)
EPUB/EPUBBuilder.swift              copy image bytes to OEBPS/images/
EPUB/XHTMLWriter.swift              render <figure><img/><figcaption/></figure>
```

**Vector-first extraction**: walk each page's `CGPDFContentStream` for
image XObjects whose bbox intersects the `.picture` region. When
filter is `/DCTDecode` or `/FlateDecode` over an image, we can extract
the original PNG/JPEG bytes losslessly. This is preferred — the
source publisher's scan stays intact.

**Raster fallback**: when the vector path doesn't return a usable
image (vector-drawn diagrams, embedded SVG, encrypted streams), crop
the rendered page raster to the region's bbox + a small margin and
write as PNG.

**Caption association**: Surya emits `.caption` regions adjacent to
`.picture`. Heuristic — a caption belongs to the figure whose bbox is
closest above (Western convention) or closest below (some fields
caption-below). Detect orientation from the first 5 figures; apply
consistently across the book.

### Tricky bits

1. **Cropping margins**: tight bbox crops cut text off the figure;
   loose crops bleed into adjacent body. Use Surya's bbox + 2% of
   page height padding, then trim using ink-density to find true
   edges.
2. **DPI choice for raster fallback**: 200 DPI is plenty for body
   figures; full-page plates need 300+. Use the source page's
   render DPI.
3. **Multi-figure layouts**: a single `.picture` region may contain
   several sub-figures with their own captions ("Fig. 3a / 3b /
   3c"). Detect via internal whitespace; split into multiple
   `.figure` blocks.
4. **Figures spanning a page break**: rare in scanned books but
   possible. Detect via aspect ratio of the picture region — if it
   abuts the bottom of one page and a similar region abuts the top
   of the next, they're likely one figure. Defer this.
5. **Cover image**: if the first page is dominated by a single
   `.picture` region, treat it as the cover. Add to OPF
   `properties="cover-image"` metadata.

### Testing

- Unit: `FigureExtractor` against synthetic PDFs with embedded
  PNG/JPEG XObjects.
- Unit: `CaptionAssociator` against synthetic region layouts.
- Integration: convert a known illustrated book (art-history
  monograph), verify all figures appear in the right positions
  in Apple Books, captions render correctly under each figure.
- Snapshot: EPUB image manifest size + count.

### Risks

- **Some PDFs have no image XObjects** — content was stamped down
  as the page itself. Raster fallback covers this.
- **Image rights**: embedded figures from copyrighted books carry
  the original publisher's rights. The app converts for personal
  use; document this in the README.
- **EPUB filesize bloat**: a 400-page art book at 300 DPI is ~80
  MB of figures. Acceptable; some readers complain past 500 MB.

### Effort estimate

~3 days: extractor + associator + Block/XHTML/EPUB plumbing + tests
+ corpus validation.

### Dependencies

None. Self-contained. Could ship next.

---

## P-Tables — Table extraction

**Status**: not started. Surya emits `.table` regions; we drop them.

### Goal

When Surya identifies a `.table` region, emit an actual EPUB
`<table>` with the right cells, not a dropped region or a flattened
paragraph.

### Approach

Two paths:

**Path A: Surya's table-recognition mode** (preferred). Surya OCR
ships a `surya-table` model that returns row/column cell structure
in addition to the bbox. Wire it into the sidecar as a third
operation alongside layout + OCR.

**Path B: heuristic from observation positions**. Cluster
observations within a `.table` region by Y position to identify rows,
then by X position within rows to identify columns. Brittle on tables
with merged cells; acceptable as a first-pass.

### EPUB output

```html
<table role="table">
  <thead>
    <tr><th>Author</th><th>Year</th><th>Edition</th></tr>
  </thead>
  <tbody>
    <tr><td>Foucault</td><td>1971</td><td>Gallimard</td></tr>
  </tbody>
</table>
```

### Risks

- Tables in scanned books are notoriously difficult. Expect 60-70%
  cell accuracy on first pass.
- Merged cells, rotated headers, and split tables across pages all
  need handling later.

### Effort estimate

~3 days for path A (Surya table model integration), ~2 days for
path B fallback, ~1 day for EPUB plumbing + tests. Total ~5-6 days.

### Dependencies

None hard, but Phase 6 figures should ship first — same XHTML
plumbing patterns.

---

## P-Math — Math / formula handling

**Status**: not started. Surya emits `.formula` regions; we drop them.

### Goal

Render math content from `.formula` regions as either MathML (best
for screen readers + EPUB 3 compliance) or as a rendered PNG of the
formula (universal compatibility, lossy for accessibility).

### Approach

**Easy path**: treat `.formula` regions as `.figure` (raster crop +
emit as `<img>`). Works on any reader, no math markup needed. Loses
the actual math semantics but at least doesn't drop the region.

**Hard path**: pluggable math OCR. Mathpix has an API. Latex-OCR is
open-source. Output → MathML → embed inline.

Recommendation: ship the easy path now (image embed) as part of
Phase 6 (essentially treating `.formula` as a kind of `.picture`),
revisit MathML if a corpus actually needs it.

### Effort estimate

~0.5 day on top of Phase 6.

### Dependencies

Phase 6 (figures) — same plumbing.

---

# Tier 2: Post-OCR LLM accuracy pass

## P-LLM-Pass — LLM-corrected OCR output

**Status**: not started. Existing `OCRTextQualityScorer` flags
low-quality regions (mojibake, single-character runs, language
confidence below threshold) and the `RegionCascade` retries with
a different OCR engine, but if every engine produces mediocre
text the bad output ships to the EPUB as-is.

### Goal

Optional post-OCR pass that sends low-quality regions (or whole
pages) to an LLM with the original text and a request to correct
obvious OCR errors. Targeted at the ~5-15% of regions our cascade
can't fix on its own — long-s misreads in 18th-century scans,
polytonic Greek where Tesseract dropped diacritics, mixed-script
boundaries, ligature confusions (`rn`→`m`, `cl`→`d`, `vv`→`w`),
missing accents on French / Spanish text Vision corrected away.

### Why this matters

The structured-doc work (chapter splitting, header/footer
classification, region splitting) is now load-bearing for output
quality but operates on whatever text the OCR cascade produces.
An LLM correction pass is the cheapest way to substantially
improve the actual character-level fidelity of the body text —
the thing the user is actually reading. Cost is well under a
penny per book at Haiku rates.

### Scope (what's in / what's out)

In:
- `OCRPostProcessor` protocol with one impl: `ClaudePostProcessor`.
- Per-region invocation gated on `OCRTextQualityScorer.combined`
  below a configurable floor (default 0.6).
- A "passages mode" — text-only correction. Send the OCR text +
  language hint + 1-2 sentence context window from neighbors.
  Cheap and fast.
- An optional "vision mode" — multimodal correction. Send the
  rendered region image + the OCR text. Higher quality on hard
  cases (worn type, faint scans), more expensive.
- A guardrail layer that compares LLM output against original
  and rejects "corrections" that look like rewrites (high edit
  distance, language drift, length explosion). Original wins on
  reject.
- An audit log per region capturing original / LLM-suggested /
  whether-accepted, surfaced in the editor's per-region inspector
  so the user can review what was changed.
- Settings: enable/disable (off by default), passages-vs-vision
  mode, quality floor for triggering, hard upper bound on calls
  per book (cost cap).

Out:
- LLM-driven layout decisions (use Surya for that).
- LLM-driven language detection (already handled by NLLanguageRecognizer
  + script-frequency analysis).
- Whole-document rewrites or stylistic edits — only character-level
  OCR corrections.

### Architecture

```
Pipeline/
├── OCRPostProcessor.swift              protocol + ChangeGuardrail
├── ClaudePostProcessor.swift           AnthropicAPIClient impl
├── OCRPostProcessorWiring.swift        gate decisions, batching
└── PDFToEPUBPipeline.swift             wire after RegionCascade

Document/
└── (no changes — the corrected text just replaces obs.text)

Humanist/
├── Settings/SettingsView.swift         + LLM correction pane
└── Editor/RegionInspector.swift        + "Show LLM correction trail"
```

### `OCRPostProcessor` protocol

```swift
public protocol OCRPostProcessor: Sendable {
    /// Correct character-level OCR errors in `text`. Returns the
    /// corrected string, or nil when the processor declines to
    /// touch this input (low confidence, off-topic content,
    /// validation failure). Caller falls back to the original
    /// when nil.
    func correct(
        text: String,
        languages: [BCP47],
        regionImage: CGImage?,         // nil for passages mode
        contextBefore: String?,        // 1-2 sentences
        contextAfter: String?
    ) async -> CorrectionResult?
}

public struct CorrectionResult: Sendable {
    public let corrected: String
    public let editDistance: Int        // chars changed
    public let confidence: Double       // model's stated confidence
    public let rationale: String?       // optional: model's note
}
```

Two impls planned:
- **`ClaudePostProcessor`** — wraps Anthropic API. Handles both
  passages mode and vision mode behind the same protocol.
- **`MockPostProcessor`** — for tests. Returns canned corrections
  keyed off input text.

### `ClaudePostProcessor` prompt design

**Passages mode** (text-only):
```
You are correcting OCR output. Fix obvious character-level OCR errors:
ligature confusions (rn→m, cl→d, vv→w), missing diacritics for the
indicated language, dropped/extra spaces around punctuation, long-s →
s in pre-1800 reprints. Do NOT change wording, do NOT translate, do
NOT modernize spelling, do NOT add or remove sentences. If the input
is already clean or you can't tell what's intended, return it
unchanged.

Languages expected: <BCP-47 list>
Context (preceding text): <up to 200 chars>
Context (following text): <up to 200 chars>

OCR text to correct:
<text>

Return JSON: {"corrected": "...", "confidence": 0.NN}
```

**Vision mode** (multimodal): same prompt, plus the rendered region
image attached. Costs ~10× more in tokens. Reserve for the lowest-
quality regions where the model genuinely needs to see the glyphs.

Pin to a specific snapshot (`claude-haiku-4-5-20251001`) for
reproducibility.

### Cost model

Haiku 4.5 at $1/MTok input, $5/MTok output.

- **Passages mode**: ~500 tokens in / 200 out per region. ~$0.001
  per region. A book with 200 pages × 5 regions/page × 10% trigger
  rate = 100 calls = $0.10/book. Cheap.
- **Vision mode**: an image at 800×600 region resolution is ~600
  image tokens. ~$0.005 per region. Same trigger rate = $0.50/book.
  Manageable but noticeable for bulk runs.
- **Hard upper bound**: configurable cap (default: 200 calls/book)
  catches runaway documents (a book where every region triggers
  would otherwise blow the budget).

### Trigger logic

The processor doesn't run on every region. Gate stack:

1. **Quality floor**: only fires when
   `OCRTextQualityScorer().score(text:).combined < 0.6`. Adjustable.
   Already-clean text is skipped — no need to spend tokens on it.
2. **Length sanity**: skip regions under 30 chars (captions,
   single-line headers — the model often makes these worse).
3. **Cost cap**: per-book counter; once exceeded, remaining calls
   skip with a debug log entry.
4. **Settings master switch**: off by default. User opts in.

### Guardrails

The `ChangeGuardrail` rejects LLM output when:
- **Edit distance > 30%** of original length: the model rewrote
  rather than corrected.
- **Length delta > 25%**: a much longer or shorter result usually
  means hallucinated content or skipped chunks.
- **Language drift**: detect script change (e.g., Latin OCR became
  Cyrillic LLM output). Reject.
- **Empty result**: model returned "" or whitespace.
- **Validation parse failure**: returned non-JSON or missing
  fields.

When rejected, original wins. Logged for editor inspection.

### Wiring into the pipeline

After `RegionCascade.run` produces final per-page observations:

```swift
if let postProcessor = ocrPostProcessor {
    observations = await applyLLMCorrections(
        observations: observations,
        regions: layoutForPage,
        pageImage: image,                  // optional, for vision mode
        languages: hints.languages,
        postProcessor: postProcessor
    )
}
```

`applyLLMCorrections` walks each text-bearing region, scores the
joined region text, fires the post-processor where the floor
allows, and replaces matching observation text with the
corrections (preserving bbox, confidence, source).

### Concurrency

Process regions in parallel via `TaskGroup` with concurrency = 5
(matches Anthropic Build-tier RPM headroom). Bulk runs serialize
books anyway, so cross-book parallelism doesn't apply.

A simple per-second token-bucket prevents bursts from tripping
rate limits on long pages.

### Settings UI

New "OCR Correction (Claude)" pane:
- "Enable post-OCR Claude correction" — master toggle
- "Mode" — Passages (text-only) | Vision (multimodal, costlier)
- "Trigger threshold" — slider for the quality floor (0-1)
- "Per-book cost cap" — number of calls before fall-back
- "Anthropic API key" — shared with Phase 2 / Phase 3 if those
  ship; standalone otherwise

### Editor integration

The region inspector pane gains a "Correction trail" disclosure
showing original / LLM-suggested / accepted / rationale per
region. Users can manually accept the LLM suggestion if our
guardrail rejected it, or revert to the original if a borderline
case got through.

### Testing

- Unit: `ChangeGuardrail` against pairs that should accept / reject
  (clean correction, hallucinated rewrite, language drift, length
  explosion).
- Unit: `ClaudePostProcessor` with mocked URLSession verifying
  prompt shape + response parsing.
- Unit: trigger-gate logic — quality floor, length sanity, cost
  cap.
- Integration: pin a fixture page with known OCR errors (1700s
  long-s text, polytonic Greek with stripped diacritics), run
  the post-processor live, assert specific corrections.
- Manual: convert a book end-to-end with correction enabled,
  verify the editor shows the trail and corrections look correct.

### Risks

1. **Hallucinated corrections**. The guardrails (edit-distance,
   length-delta, language-drift) catch the obvious cases but not
   subtle rewrites. The editor trail makes them auditable.
2. **Cost runaway** on a book where every region triggers. The
   per-book cap defends.
3. **Latency at bulk scale**. 200 calls × 1 second each is 3
   minutes added per book. Concurrency helps; the user can opt
   out for time-sensitive runs.
4. **API key dependency**. Same posture as Phase 2 / 3 — store in
   Keychain, fall back silently when missing.
5. **Multilingual reliability**. Haiku handles classical Latin and
   French well; less reliable on polytonic Greek, Hebrew, Syriac.
   Vision mode helps for the harder cases. Worst case: corrections
   reject and we keep the original Tesseract output.
6. **Reading-order coupling**: the post-processor sees one region
   at a time, so it can't fix errors that cross region boundaries
   (a hyphenated word split across regions). Acceptable scope
   limitation.

### Effort estimate

- ~1 day: protocol + ChangeGuardrail + tests
- ~1 day: ClaudePostProcessor (passages mode) + tests
- ~0.5 day: Vision-mode extension
- ~0.5 day: wiring into pipeline + trigger gate
- ~0.5 day: Settings UI + Keychain integration (or share with
  Phase 2/3 if they shipped first)
- ~0.5 day: editor inspector "Correction trail" pane
- ~1 day: corpus testing (5-10 fixture books) + threshold tuning

Total: ~5 days for a polished implementation.

### Dependencies

- **Anthropic API client** is shared with Phase 2 / Phase 3. If
  this ships first, those plans inherit the `URLSession`
  wrapper + Keychain code. Build it cleanly here so reuse is
  trivial.
- **Editor inspector** already shows per-region info; just adds
  a new disclosure section.
- **Quality scorer** is already in place — this consumes its
  output, no changes needed there.

---

# Tier 3: Language + corpus expansion

## P9 — RTL languages: Hebrew, Syriac, Coptic

**Status**: not started. Architecture supports it; no work done.

### Goal

OCR + render Hebrew, Syriac, Coptic, and similar RTL / mixed-script
texts. Output EPUBs render with `dir="rtl"` blocks and correct
glyph order for each script.

### Scope

In:
- `heb_best.traineddata` (Hebrew)
- `syr_best.traineddata` (Syriac)
- `cop_best.traineddata` (Coptic — Bohairic + Sahidic both rendered
  by the same data)
- BCP-47 language codes added to language picker (`he`, `syr`, `cop`)
- `RegionRouter` updated to send these to Tesseract preferentially
  (Vision is weak on these scripts)
- `XHTMLWriter` per-block `dir="rtl"` when block's dominant
  language is RTL
- `EPUBBuilder` per-document `<spine page-progression-direction="rtl">`
  when the dominant language is RTL
- Bidi text handling: Hebrew with embedded Latin (transliterations)
  needs `<bdo dir="ltr">` wrappers. Detect via Unicode bidi
  classification.
- Bundle a polytonic + Hebrew capable font in OEBPS/fonts (the
  original plan called this out — Noto Serif covers everything).

Out:
- Arabic (different vowel-marking / shaping concerns; bigger lift)
- Devanagari / Sanskrit (different script family entirely; defer)
- Coptic Sahidic vs Bohairic dialectal disambiguation — use the
  same traineddata, accept some confusion

### Tricky bits

1. **Mixed direction within a paragraph**: Hebrew quotation in an
   English paragraph needs `<span dir="rtl">` even when the parent
   block is LTR. Detect via Unicode `BidiClass`; emit spans
   selectively.
2. **Polytonic Greek + Hebrew on the same page** (Septuagint
   editions): each region tagged with its own language; reflow
   handles the rest.
3. **Tesseract lang stacking**: Tesseract can take `heb+lat` to
   handle mixed text, but quality drops vs single-lang. Use
   single-lang per region when layout localizes the boundary;
   fall back to combined when not.
4. **Right-to-left in the editor**: the SwiftUI / WKWebView
   preview pane needs to honor `dir="rtl"`. WKWebView does this
   natively if the XHTML carries the attribute. Verify the source
   pane (CodeMirror) handles RTL editing — recent versions do.

### Testing

- Unit: language routing for `he`/`syr`/`cop` codes.
- Integration: convert a Hebrew Bible page (Aleppo / Leningrad
  facsimile), a Syriac Peshitta page, a Coptic NT page. Ground-
  truth at least the first page.
- Manual: open results in Apple Books and verify glyph order, line
  direction, and font fallback.

### Risks

- **Tesseract `heb_best` accuracy on mediaeval / palaeographical
  scans is mediocre**. Same caveat as polytonic Greek (the
  original plan's risk #2). For high-quality output, may need to
  train custom data on a corpus we have access to.
- **Bidi rendering bugs in EPUB readers**. Apple Books handles
  most cases; some Kobo / Thorium edge cases exist for
  Latin-in-RTL spans.

### Effort estimate

- ~1 day: traineddata + language picker plumbing
- ~1 day: RTL block emission + bidi detection
- ~0.5 day: font bundling
- ~1 day: corpus testing on real Hebrew / Syriac / Coptic books
- ~0.5 day: editor-side RTL verification

Total: ~4 days. Less if we accept "working but not perfect" for
the bidi edge cases.

### Dependencies

None hard.

---

## P-Greek-Quality — Polytonic Greek accuracy spike

**Status**: not started. The original plan's risk #2.

### Goal

Measure Tesseract `grc_best` Character Error Rate against
hand-corrected ground truth on a real classical-text corpus. If
CER > 5%, evaluate alternatives (TrOCR, GOT-OCR2, fine-tuned
custom traineddata).

### Approach

1. Pick 5-10 ground-truth pages (Loeb, OCT, Teubner, papyri).
2. Run them through the existing Tesseract path; capture output.
3. Hand-correct each page in a separate text file.
4. Compute CER using a standard library (jiwer in Python or
   Swift equivalent).
5. If CER < 3%, ship as-is.
6. If CER 3-5%, document the limitation and continue.
7. If CER > 5%, evaluate replacement — Microsoft TrOCR has
   classical Greek checkpoints; Surya's OCR model handles
   polytonic better than Tesseract on some pages.

### Effort estimate

~2 days for the measurement and decision. Implementation of an
alternative, if needed, is a separate ~5-day project.

### Dependencies

None.

---

# Tier 4: Distribution + polish

## P10 — Distribution

**Status**: app is signed and runs locally. Not packaged for
distribution. Surya runtime relies on a separate `uv tool install
surya-ocr` step on the user's machine.

### Goal

A user downloads a single notarized DMG, drags `Humanist.app` to
`/Applications`, double-clicks. Conversion works without any
additional setup. App auto-updates via Sparkle.

### Sub-deliverables

#### 10.A — Bundle the Python sidecar runtime

Today the sidecar uses `~/.local/share/uv/tools/surya-ocr/bin/python`
auto-detected at runtime. Move to a self-contained bundle:

- Vendor `python-build-standalone` (CPython 3.12 arm64 relocatable)
  into `Resources/python/`.
- Pre-install Surya + PyTorch into a frozen venv in
  `Resources/python/lib/python3.12/site-packages/`.
- Pre-download Surya weights to `Resources/surya-models/`; set
  `HF_HOME` so the app never tries the network.
- `Scripts/bundle-python.sh` — automate the assembly.
- `Scripts/sign-embedded-binaries.sh` — walk the bundle tree and
  individually code-sign every Mach-O (`.so`, `.dylib`, executable).
  Notarization fails on the first unsigned binary.
- Required entitlement:
  `com.apple.security.cs.disable-library-validation` (per the
  original plan — friendlier to notarization than the
  unsigned-executable-memory entitlement).

Bundle size: ~1.8 GB total. Acceptable for direct distribution.

This is the single biggest risk in distribution work. The original
plan called this out as risk #1; the spike (Phase 0) verified it's
possible but the production wiring isn't done.

#### 10.B — Bundle Tesseract + traineddata

Today Tesseract is linked against `/opt/homebrew/lib/libtesseract.5.dylib`
on the user's machine. Move to vendored:

- Build `libtesseract` (5.4+) and `libleptonica` (1.84+) from source
  for arm64, output to `Vendor/tesseract/`.
- `install_name_tool -id @rpath/libtesseract.5.dylib …` post-build.
- Ship `_best` variants of `eng`, `grc`, `lat` in `Resources/tessdata/`.
  Add `heb`, `syr`, `cop` if Phase 9 has shipped.
- Code-sign every dylib in the build script.

#### 10.C — DMG assembly

- `Scripts/build-dmg.sh` — produce a DMG with a background image,
  `/Applications` symlink, and the .app bundle.
- Notarize via `notarytool`. Staple the ticket.

#### 10.D — Sparkle for in-app updates

- Vendor Sparkle 2.x.
- `appcast.xml` hosted somewhere (GitHub Pages is fine).
- Generate update on each release; Sparkle handles delta + signature
  verification.

#### 10.E — README + user docs

- Brief README at the repo root explaining what the app does.
- A user guide PDF (or Markdown rendered to a built-in Help menu)
  covering: drag-drop, queue, editor, language picker, two-up
  detection, the high-accuracy mode toggle.
- A developer guide for adding language support.

### Effort estimate

- 10.A: ~3 days (the spike work plus production hardening)
- 10.B: ~1.5 days
- 10.C: ~0.5 day
- 10.D: ~1 day
- 10.E: ~1 day
- End-to-end testing on a clean Mac: ~0.5 day

Total: ~7-8 days.

### Risks

- **The Python bundle**: the spike worked but bundle is the riskiest
  long-tail thing in the project. Plan time for "find which `.so`
  Apple's notary doesn't like; iterate."
- **Bundle size**: ~1.8 GB is fine for direct download but rules
  out App Store distribution forever.
- **Sparkle update hosting**: needs a stable URL. GitHub Pages
  works for free but requires manual upload.

### Dependencies

None hard. 10.A and 10.B are independent; 10.C-D require both
to be done.

---

# Tier 5: Quality refinements

These are smaller items that follow naturally from work we've done.

## R-Footers — Cross-page running-footer recurrence

**Status**: cross-page recurrence is implemented for top-zone running
heads. Symmetrically applies to bottom-zone running footers but the
code today only operates on the top zone.

### Goal

Apply the same cross-page recurrence logic to the bottom zone so
recurring "Stoicheia I.iii" or chapter-bottom labels get tagged as
`.pageFooter` instead of `.text`.

### Approach

`RegionAwareReflow.classifyTopRegionsByRecurrence` becomes
`classifyEdgeRegionsByRecurrence` and runs once for each edge zone.
Symmetric thresholds.

### Effort

~0.5 day. Pure refactor + tests.

---

## R-Hierarchy — Multi-level chapter / section / part structure

**Status**: ChapterSplitter only splits at H1. H2 and H3 headings
become inline content in the chapter rather than nested nav entries.

### Goal

Detect a hierarchy (Part → Chapter → Section → Subsection) from H1 /
H2 / H3 boundaries and emit a nested EPUB nav.

### Approach

Walk the block stream. H1 starts a chapter (existing behavior). H2
within a chapter becomes a "section" within the chapter's nav entry.
nav.xhtml emits nested `<ol>` accordingly.

Optionally: split very long chapters into separate XHTML files at H2
boundaries (some EPUB readers struggle with 100-page chapters).

### Effort

~1 day.

### Dependencies

Naturally combines with Phase 3 (TOC parsing) — TOCs typically
encode the same hierarchy.

---

## R-Custom-Styles — Per-book CSS / fonts

**Status**: every EPUB ships with the same minimal `book.css`. No
per-book customization.

### Goal

Editor pane that lets the user choose a font + size + color theme,
preview it live in the WKWebView, save into the book's CSS.

### Effort

~1 day for a basic font picker + serif/sans toggle. More for a
real theming system.

---

## R-Search — Full-text search in the editor

**Status**: editor has CodeMirror's built-in find but it's limited
to the current pane.

### Goal

Cross-chapter search that returns hits with context, jumps to the
matching XHTML location.

### Effort

~1.5 days.

---

## R-Library — Library browser window

**Status**: Recents menu shows last 10 opened EPUBs. No full library
view.

### Goal

A library window listing every EPUB the user has converted, with
thumbnails (from the cover image — depends on Phase 6), filter by
language, sort by last-opened.

### Effort

~2 days.

### Dependencies

Phase 6 (cover image extraction).

---

## R-Bulk-Editor — Bulk editor operations

**Status**: editor operates on one EPUB at a time. No way to apply
the same change across many converted books.

### Goal

Operations like "re-OCR every page in language X" or "replace this
phrase across these N books" — useful when a corpus update is
needed without redoing every book individually.

### Effort

~3 days.

---

# Tier 6: Performance + observability

## P-Surya-Pool — Multiple Surya sidecars for parallelism

**Status**: one shared Surya sidecar serves all pipelines. Sequential
per page. The bulk runner serializes books anyway, so this is fine
today.

### Goal

If we ever want to convert multiple books in parallel (or process
more pages per second on a single book), pool 2-4 Surya sidecars.
Each loads ~5 GB of weights; pool size is bounded by physical
memory.

### Approach

`SuryaConnectionPool` with a fixed size; round-robin or
least-loaded dispatch.

### Effort

~1 day.

### Dependencies

JobRunner concurrency change (currently single-job).

---

## P-Vision-Concurrency — Overlap Vision OCR with Surya layout

**Status**: per-page work is serial: render → Vision → Surya layout →
cascade.

### Goal

Render → start Vision and Surya in parallel → join when both done.
~30% per-page speedup.

### Effort

~0.5 day. Just `async let` in the per-page loop.

---

## P-Shared-Memory — Surya IPC via shared memory

**Status**: PNG encoded → tmpfile → Python reads. ~50ms per page of
overhead.

### Goal

Pass image bytes via POSIX shared memory or via a memory-mapped
file. Python decodes from the buffer directly.

### Effort

~2 days. Probably not worth it on Apple Silicon — the tmpfile
hits APFS's compressed pages and is fast enough.

---

## O-Telemetry — Optional telemetry

**Status**: original plan said no telemetry. Still appropriate for
personal use.

If ever distributed more widely:
- Crash reporter (Sentry / Bugsnag / Apple's built-in).
- Optional usage telemetry (gated on a Settings opt-in).

Keep no-telemetry-by-default. Document it in the README.

---

# Tier 7: Testing + CI

## T-CI — GitHub Actions CI

**Status**: `swift test` runs locally; nothing in CI.

### Goal

Every push runs `swift test`. PR badges. Optional notarization on
release tags.

### Effort

~0.5 day.

---

## T-Snapshot-EPUBs — EPUB snapshot tests

**Status**: have unit + integration tests but no EPUB-output
snapshots. A regression in OPF / nav / XHTML structure shows up
only when manually inspecting outputs.

### Goal

Snapshot the structure of generated EPUBs for fixture inputs.
Stored in the repo; diffs surface regressions.

### Effort

~1 day.

---

## T-Memory-Regression — Memory regression test

**Status**: 100 GB leak found and fixed empirically. No automated
test prevents recurrence.

### Goal

A test that converts N books in sequence and asserts the host
process's RSS doesn't grow past a threshold. Run on demand
(too slow for every test run).

### Effort

~1 day.

---

## T-Real-Corpus — Real-corpus regression suite

**Status**: tests use synthetic fixtures. Real-world quality is
verified manually.

### Goal

A separate `TestDocuments/` repo (kept out of the app repo for
size reasons; per the original plan) with hand-corrected ground
truth for the first 5 pages of a representative corpus. CER /
WER tracked across releases so accuracy regressions surface
automatically.

### Effort

~3 days for a 10-book corpus + ground truth + CI integration.

---

# Tier 8: Stretch / speculative

## S-Apple-Intelligence-Polish

When macOS 26+ becomes the realistic minimum, use Foundation Models
(see [Plans/Phase2-Semantic-Classification.md](Plans/Phase2-Semantic-Classification.md))
for chapter classification. Cleaner than cloud Claude and free.

## S-Custom-Footnote-Style

EPUB 3 popup footnotes can be styled per-publisher (margin notes,
inline notes, etc.). Could expose this as a per-book setting.

## S-Audio-Output

EPUB 3 supports Media Overlays (audio synced to text). Could
generate using Apple's `AVSpeechSynthesizer` and bundle the audio
with the EPUB. Niche but unique.

---

# Recommended ordering

If picking up from here cold, this is roughly the order I'd tackle
things in. The user's stated priorities are quality output + personal
use; distribution is lower priority than correctness.

1. **Phase 6 (figures + tables + math-as-image)** — biggest visible
   gap. ~5-6 days for figures + tables. Math-as-image included.
2. **P-LLM-Pass (post-OCR Claude correction)** — biggest invisible
   gap. The OCR cascade does what it can; the final ~5-15% of
   character-level errors need an LLM to clean up. Ships the
   Anthropic API client, Keychain key storage, and editor
   correction-trail UI that Phase 2/3 will reuse. ~5 days.
3. **Phase 9 (RTL + Hebrew/Syriac/Coptic)** — opens up a substantial
   corpus. ~4 days.
4. **R-Hierarchy** (multi-level chapters) — natural follow-on to
   ChapterSplitter, low effort. ~1 day.
5. **R-Footers** (cross-page running footers) — symmetric refactor.
   ~0.5 day.
6. **Defer Phase 10 (distribution)** until the user actually wants
   to share or onboard another machine. The app is signed and runs
   locally; that's enough for personal use.
7. **AI-assisted Phase 2/3** — pick up when the user wants
   structured TOCs or semantic landmarks. Existing plans in
   `/Plans/`. Builds on the API key + Keychain plumbing P-LLM-Pass
   ships first.

Total Tiers 1-3: ~15-17 days for substantial quality + corpus
expansion. After that the app handles essentially any book a
working researcher would feed it.
