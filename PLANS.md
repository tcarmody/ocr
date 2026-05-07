# Humanist — Outstanding Plans

A consolidated picture of work remaining on Humanist. Read this first
in any new session — it's the canonical "where do we go from here"
document.

For deep design docs on the AI-assisted structured-document work,
see [Plans/Phase2-Semantic-Classification.md](Plans/Phase2-Semantic-Classification.md)
and [Plans/Phase3-TOC-Parsing.md](Plans/Phase3-TOC-Parsing.md). The
prompt shapes / guardrails / editor-trail designs in those docs
remain architecturally valid; they predate the hybrid Private/Cloud
architecture decision and now slot into Cloud Phase 6 (Tier 2
below). The `AnthropicAPIClient` and Keychain plumbing they assume
already exists from Cloud Phase 1 (commit `567d2c3`).

---

## Status snapshot (as of 2026-05-06)

**Done from the original 10-phase plan**:
- Phase 0: notarized python-build-standalone spike
- Phase 1: walking skeleton (drop PDF → Vision OCR → EPUB)
- Phase 2: embedded text extraction + quality scoring
- Phase 3: Tesseract integration (linked via C API, not the CLI)
- Phase 4: Surya layout sidecar + per-region cascade
- Phase 5: footnote detection + EPUB 3 popup linking
- Phase 6: figure extraction (raster crop + caption association),
  table extraction (Surya `TableRecPredictor` integration with
  heuristic Y/X clustering as fallback), math (`.formula` regions
  take the figure raster path with `alt="formula"`)
- Phase 7: bulk job queue + drag-drop folders + GRDB-free persistence
- Phase 8: side-by-side editor (PDF / source / preview, linked nav)

**Done above the original plan** (quality + robustness):
- Two-up scan detection + auto-split pipeline
- Memory hardening (per-page autoreleasepool, periodic PDF reload,
  shared Surya sidecar singleton, editor deinit, drain sidecar
  PyTorch cache + Vision NSObject pool)
- Header / footer reclassification (per-page heuristic + page-number
  bypass + cross-page recurrence pass)
- Footnote heuristic for `.text` regions Surya mislabeled
- Region splitting at internal gap (Surya-merged body+footnote)
- Heading reading-order correction (top-of-page headings Surya
  ordered after body)
- ChapterSplitter — flat block stream → multi-chapter Book IR

**Done — Cloud-mode foundation** (Tier 2's first two phases of
the hybrid Private + Cloud architecture):
- **Cloud Phase 1**: Anthropic API plumbing in a new `AI` library
  target. Request / response types with prompt-caching support,
  `URLSessionTransport` behind a protocol so a future Batches
  API runner reuses every other type unchanged, Keychain-backed
  `AnthropicAPIKeyStore`, `AISettings` persisted to UserDefaults,
  Settings scene (⌘,) with the master Private/Cloud toggle +
  per-feature switches + cost cap + connection test.
- **Cloud Phase 2**: `ProcessingMode` plumbed end-to-end through
  `PDFToEPUBPipeline.Options` and `JobRunner`. Explicit dispatch
  switches at the OCR cascade and table-extractor sites. Both
  arms route identically today — they're scaffolding for the
  per-engine swaps that ship in Cloud Phases 3+. Existing tests
  pass unchanged on `.privateLocal`.

**Done — Cloud-mode hard-region OCR + post-OCR cleanup**:
- **Cloud Phase 3** (commits `9a4adfd`, `567d2c3`): `ClaudeOCREngine`
  wired in as the cascade's final tier under `.cloud` mode. Sonnet
  vision; gated on `cloudFeatures.hardRegionOCR` + per-book
  `ClaudeCallBudget`. Replaces what was originally P-LLM-Pass's
  "vision mode."
- **Cloud Phase 4** (commit `9a4adfd`): validation spike against the
  Aeschylus polytonic-Greek ground truth — Local 15.1% CER, Cloud
  full-cascade 15.1% (Claude not invoked because Tesseract output
  passed the quality floor), Claude-only 11.3%. Confirmed the
  cascade gating works and Claude-only is the upper-bound quality
  for this content.
- **Cloud Phase 6 — passages mode** (commit `c6564bd`):
  `ClaudePostProcessor` with Haiku 4.5, gated on
  `OCRTextQualityScorer.combined < 0.6`. Reuses
  `OCRChangeGuardrail` for accept/reject. Wires into the pipeline
  after `RegionCascade.run`.
- **Cloud Phase 6 — vision mode** (commit `ae99693`):
  `ClaudePostProcessor.Mode = .passages | .vision`. Vision sends
  the cropped region image alongside the OCR text. Costs ~5–10×
  more in tokens; reserve for the hardest regions. Sub-toggle in
  Settings disabled when cleanup itself is off.
- **Cloud Phase 6 — interactive correction trail** (commit `f91d0e0`):
  Per-region trail entries (accepted *and* guardrail-rejected) write
  to `META-INF/com.humanist.correction-trail.json` as an editor-only
  sidecar. New `CorrectionTrailSheet` shows entries grouped by page
  with side-by-side original/suggested text, status badges, copy
  buttons, **Reveal in Source**, and **Apply / Revert** actions.
  Apply/revert use whitespace-tolerant find-and-replace with
  graceful fallback ("text didn't survive reflow byte-for-byte —
  use Reveal in Source and paste manually") rather than mangling
  the file when the match is missing or ambiguous.

**Done — Cloud-mode structural Haiku features (Cloud Phase 6 final pieces)**:
- **Cloud Phase 6d — Semantic chapter classification** (commit
  `e985946`): per-chapter `epub:type` tagging via Haiku, with the
  English regex classifier as the offline fallback. Multilingual
  headings (Préface / Vorwort / Praefatio / ΠΡΟΛΟΓΟΣ) handled.
- **Cloud Phase 6e — Printed-TOC parsing** (commits `bd466f3`,
  `e3eb46c`): `TOCDetector` + `TOCExtractor` + `ClaudeTOCParser`
  produce a structured TOC tree; `nav.xhtml` is driven by the
  parsed TOC when one is available, and chapter titles
  authoritative-override Surya's heading reads.

**Done — Cloud Phase 7**:
- **First-run welcome sheet + README rewrite** (commit `e42253f`).
  Cloud-vs-Private explanation, API-key onboarding link, and a
  rewritten README that reflects the hybrid architecture.

**Done — Claude Page OCR (whole-page Sonnet path)** (commits
`766bcfe`, `569c421`, `cba7f64`, `0130e34`, `8442e37`, `3d8e4c3`):
A second cloud OCR pathway that bypasses the per-region cascade
entirely. One Sonnet call per page returns structured XHTML →
`[Block]` + `[Footnote]` directly. Handles its own headings,
footnotes, language spans, and footnote-ref linking. Surya layout
still runs in parallel for figures + tables. Per-page checkpoint
+ resume preserves extracted figures across interruptions.
~$0.04/page (~$15–25/book) with the `Claude OCR ($$$)` toggle in
the launcher; the legacy Vision→Sonnet cascade-tail is dev-only
(`useCloudEnhancedOCR`) and not reachable from the UI. Private
Mode toggle (commit `8442e37`) forces empty CloudFeatures + empty
key per-job, zero Claude traffic regardless of global Settings.

**Done — Tier 1.5 (pre-flight intelligence)**:
- **P-Lang-Detect** (commit `5a65827`): `DocumentProfiler` samples
  three evenly-spaced body pages of each dropped PDF, runs
  `NLLanguageRecognizer` on the embedded text, and emits a
  `DocumentProfile` (primary + secondary languages, confidence,
  scan-likely flag). Confidence ≥ 0.7 + supported language → the
  job's `options.languages` is overridden to match. New
  `.profiling` job status during the brief detection window;
  recovers cleanly across crashes.
- **P-Cloud-Cost** (commit `ddef56d`): `CostEstimator` produces a
  pre-flight call/dollar estimate keyed off the document profile
  + enabled Cloud features + page count. Surfaced in the queue UI
  before the job runs. Honors the page-OCR path's per-page Sonnet
  pricing when `useClaudePageOCR` is on (replacing the per-region
  hard-region-OCR + post-OCR-cleanup line items with a single
  per-page Sonnet line).
- **P-Profile-Warnings** (commit `e8ac7bd`): non-blocking nudges
  in the queue row when the profile suggests a different config
  would do better (e.g. detected language ≠ picker language).

**Done — R-Conversion-Summary** (commit `e17cde8`): Claude calls
+ approximate cost surfaced per-job in the queue UI after each
conversion via the `ConversionStats` struct returned from
`PDFToEPUBPipeline.convert()`.

**Done — Pipeline / cascade refinements**:
- Image preprocessing + adaptive DPI on scan-likely pages
  (commit `c5e01d9`).
- DictionaryCorrector moved from per-region to post-reflow,
  running before Haiku post-OCR cleanup (commits `bcebcb2`,
  `eba13c2`).
- Cascade Cloud-enhanced (Vision→Sonnet) toggle + tightened
  thresholds (commit `141fc3f`) — kept as a dev path; not
  reachable from the user-visible toggle, which now drives the
  whole-page OCR engine instead.
- ChapterSplitter splits at the dominant heading level, not just
  H1 (commit `6fc98ca`); false-heading filter rejects drop caps,
  body fragments, and recurring running heads as chapter
  boundaries (commit `d1f4dc1`).
- ColumnSplitter / RegionAwareReflow span-aware: header /
  epigraph spanning both columns no longer collapses two-column
  reading order to row-major (commit `ba7ec62`).
- SidecarBridge actor reentrancy fix that deadlocked concurrent
  `send()` (commit `830d400`).
- Per-page checkpoint + resume from interrupted conversions
  (commit `f3ee05b`); extended to the page-OCR path with mode
  guard so cascade-shape and page-OCR-shape checkpoints don't
  mix mid-conversion (commit `0130e34`).
- Save log toggle in launcher options (commit `75c1a3f`) — keeps
  staging dir + writes diagnostic log next to the EPUB.
- OCR toggles renamed: "Claude OCR" + "Surya OCR" (commit
  `3d8e4c3`); Claude OCR labeled with cost indicator (commit
  `766bcfe`).

**Done — UX cleanups**:
- Force OCR toggle bypassing the embedded-text trust path (commit
  `7654e68`).
- Embedded-text scorer language gates: language-mismatch downgrade
  + language-confidence floor + confusable allowlist
  (`grc↔el`, `la↔Romance`, `chu↔Slavic`) (commit `7654e68`).
- Conversion-stats summary calls out the trust verdict — "Trusted
  embedded PDF text on all N pages — OCR did not run" (commit
  `7654e68`).
- Build/launch pipeline switched to `Scripts/run-app.sh` so the
  built `.app` bundle includes CodeMirror + sidecars (without it,
  the source-editor pane was blank).
- File menu Save / Save As routed via `EditorCommandRouter` (a
  keyWindow-driven singleton) instead of the unreliable
  `@FocusedObject` propagation through `CommandGroup(replacing:
  .saveItem)`. `replacing: .saveItem` switched to `after: .newItem`
  on macOS 26 / Tahoe where the former placement was a silent
  no-op for non-DocumentGroup apps.
- 3-way editor sync rewritten to one-way explicit alignment
  (commit `d4e3c41`). Bidirectional auto-sync removed; three new
  Document menu commands (⇧⌘1/2/3) drive alignment from the
  source / PDF / preview pane on demand. File switch via the
  browser still aligns once.
- Launcher window: status strip, compact options row, adaptive
  drop zone (commit `56bf252`).

**Done — Editor enhancements**:
- Source editor formatting toolbar above the CodeMirror pane
  (commit `4292cf3`).
- Smart quotes + spellcheck + find/replace (commit `55ee3aa`);
  NSSpellChecker-backed full-document spelling sheet with
  find/replace (commit `d7b7722`); customization options +
  `SPELLING.md` per-book alternatives (commit `2a0611d`); single
  full-document spell call + lazy guesses (commit `bb74d62`);
  spellcheck attribute forced on CodeMirror's stable wrapper
  (commit `ab91db0`).
- Format / Insert / Edit menus + Special Character + Goto Line
  (commit `d05ad8d`).
- Chapter Split / Merge / Regenerate TOC (commit `3f8ab64`).
- Find in All Files — cross-chapter search + replace +
  go-to-source (commit `baea472`).
- Validate EPUB — `epubcheck` wrapper (commit `7179c11`).

**Done — Cloud Phase 5**:
- **`ClaudeTableExtractor`**: Sonnet-driven table structure behind
  a new `TableExtractor` protocol. `SuryaTableExtractor` adopts
  the same protocol; under `.cloud` mode the pipeline tries
  Claude first per `.table` region and falls back to the Surya
  path on nil (decline / refusal / parse failure / sub-2×2 grid).
  `RegionAwareReflow`'s `TableHeuristic` remains the final
  fallback when both extractors return nil. Same gating shape as
  the other Cloud helpers (`.cloud` mode + `tableExtraction`
  toggle + API key); the toggle was already exposed in the
  Settings pane and the cost estimator's table line item.

**Cloud-mode features remaining** (Tier 2):
- **Cloud Phase 8** (deferred): per-book mode override for
  sensitive material when default is Cloud — partially obsoleted
  by the Private Mode toggle that already ships per-job override.

**Original-plan items still outstanding**:
- Phase 10 — Polish + distribution (Sparkle, DMG, bundled Python)

**Original-plan items deferred indefinitely**:
- Phase 9 — RTL / non-Latin classical scripts (Hebrew, Syriac,
  Coptic). Architecture supports adding them, but the user's
  working corpus doesn't need them often enough to justify the
  bidi rendering edge cases and the per-script Tesseract
  weaknesses. Revisit if a Hebrew / Syriac / Coptic project comes
  up — design notes are still in the P9 section below.

---

# Tier 1: Immediate quality gaps

Things the user has either flagged or will flag the next time they
open an academic / illustrated book.

## P6 — Figure extraction

**Status**: shipped (commits `81109c4`, `a145dcc`).
`FigureExtractor` raster-crops `.picture` and `.formula` regions
from the rendered page; `CaptionAssociator` pairs each figure
with the nearest `.caption` (orientation locked book-wide from
the first 5 figures); `RegionAwareReflow` emits `Block.figure`;
`EPUBBuilder` writes `OEBPS/images/<id>.png` with proper OPF
manifest entries (and `properties="cover-image"` for the
page-0 dominant-figure cover heuristic). Vector-XObject
extraction deferred — raster path is correct for scanned
facsimiles and fine for born-digital at our render DPI.

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

**Status**: shipped, all three paths (commits `915c1d0`,
`5473199`, plus Cloud Phase 5). Path A — Surya
`TableRecPredictor` — runs as the offline backend;
`SuryaTableExtractor` crops the page, sends to the sidecar,
translates pixel polygons back to full-page normalized coords,
and maps OCR observations onto cells. Cloud Phase 5 added a
`TableExtractor` protocol with `ClaudeTableExtractor` (Sonnet
4.6) as the per-region first choice under `.cloud` mode; the
Surya path is the offline fallback when Claude declines or
returns a sub-2×2 grid. Path B — `TableHeuristic` Y/X
clustering inside `RegionAwareReflow` — remains the final
fallback when neither extractor produces a usable grid. All
paths feed `Block.table`; `XHTMLWriter` renders proper
`<table role="table">` with `<thead>` / `<tbody>` /
`<caption>` / merged-cell spans. CSS in `book.css`.

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

**Status**: shipped as part of Phase 6 figures (commit `a145dcc`).
`.formula` regions take the same raster path as `.picture` and
emit `Block.figure` with `alt="formula"` (or the caption text,
when a caption is associated). Real MathML / Mathpix / Latex-OCR
remains deferred — no corpus has demanded it yet.

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

# Tier 1.5: Pre-flight intelligence

Smart defaults set at queue-add time. Same architectural shape as
`TwoUpDetector` — sample a few pages at low DPI, populate
`ConversionOptions` defaults, surface info in the queue UI. **Doesn't
touch the runtime cascade**; the cascade is already an adaptive
per-region system. This tier is about user-facing defaults,
warnings, and cost transparency, not engine selection.

**Why this exists**: the cascade adapts at runtime, but the
user-facing defaults are static. Today the user picks a language
manually, doesn't see Cloud-mode cost until after the conversion
has already run, and can mismatch options to content (English
picker on a Greek book). Pre-flight closes those gaps without
fighting the cascade's existing adaptivity.

**What this tier is NOT** (and should never become):

- **Per-document engine routing** — picking which OCR engine to
  use for a whole PDF. Documents are heterogeneous (preface in
  Latin, body in Greek, footnotes in English); the per-region
  cascade is correct here, and a per-document override would
  fight it.
- **Auto-toggling Cloud features** based on detected content.
  Nudges yes; auto-spend no.
- **Document-similarity ML** ("books like this one used
  Tesseract"). Premature — no telemetry to learn from, cascade
  does the routing dynamically anyway.

## P-Lang-Detect — Auto-detect document language(s)

**Status**: shipped (commit `5a65827`).
`PDFIngest/DocumentProfiler` samples 3 evenly-spaced body pages,
reads embedded text via PDFKit, runs `NLLanguageRecognizer`, and
emits a `DocumentProfile` (primary + secondary language codes,
confidence, scan-likely flag). When confidence ≥ 0.7 and the
detected language is in the picker's supported set, the job's
`options.languages` is overridden to match. New `.profiling` job
status during the brief detection window. Vision-OCR fallback for
scanned PDFs is deferred — would block queue-add on per-page
Vision latency; current path returns `isLikelyScan: true` and the
picker fallback covers it.

## P-Cloud-Cost — Pre-flight Cloud-mode cost estimate

**Status**: shipped (commit `ddef56d`; page-OCR pricing extension
in commit `0130e34`). `CostEstimator` produces a per-book Claude
call + dollar estimate from the document profile, page count,
and enabled Cloud features. Surfaced in the queue UI before
conversion runs. Honors `useClaudePageOCR`: when on, replaces
the per-region hard-region-OCR + post-OCR-cleanup line items
with a single per-page Sonnet line (~$0.04/page).

### Goal

In `.cloud` mode, show the user an estimated number of Claude
calls + dollar cost before kicking off conversion. Avoids the
"I just spent $5 on a 600-page book I didn't realize was that
big" surprise.

### Approach

1. Reuse `DocumentProfiler` from `P-Lang-Detect`. Add: total page
   count, regions per page, scan vs born-digital, table density.
2. Apply a per-feature trigger-rate model — e.g.:
   - Hard-region OCR fires on ~10% of regions on a scanned book,
     ~0% on a born-digital one.
   - Table extraction fires on detected `.table` regions
     (Surya layout pre-pass on 1 sample page).
3. Multiply trigger counts by current Sonnet / Haiku rates pinned
   in `AnthropicModel`.
4. Surface in the queue UI as "≈80 Claude calls, ≈$0.25 estimated"
   with a "Convert" / "Cancel" gate before the job actually starts.

### Effort

~1 day on top of `P-Lang-Detect` (rate table + UI banner +
gate flow).

### Dependencies

Phase 3 (Claude OCR) at minimum; ideally Phase 5 (Claude tables)
too so the estimate reflects all enabled features.

## P-Profile-Warnings — Banner warnings for content-vs-config mismatches

**Status**: shipped (commit `e8ac7bd`). Non-blocking nudges in
the queue row when the document profile suggests a different
config would do better.

### Goal

Non-blocking info banner when the document profile suggests a
different config would do better. Examples:

- Polytonic Greek detected, English picker selected → "Better
  quality with Greek + Tesseract"
- Heavy table density detected, table extraction toggle off →
  "Table extraction will skip this book"
- Math density detected, no formula handling planned →
  "Formulas will render as raster images"
- Document detected as scanned facsimile but
  `useHighAccuracyOCR == false` → "Surya may help — try the
  high-accuracy toggle"

### Approach

The profile already exists from `P-Lang-Detect` + `P-Cloud-Cost`;
this is a thin presentation layer on top — a list of
`ProfileWarning` rules + a queue-UI banner.

### Effort

~0.5 day on top of `P-Lang-Detect`.

### Dependencies

`P-Lang-Detect`.

## Recommended sequencing within this tier

All three pieces of Tier 1.5 have shipped:

1. ~~`P-Lang-Detect`~~ shipped.
2. ~~`P-Cloud-Cost`~~ shipped.
3. ~~`P-Profile-Warnings`~~ shipped.

---

# Tier 2: AI-assisted enhancements (Claude)

This tier collects every feature that depends on calling out to
Claude via the Anthropic API. The architecture is **hybrid by
design**: Private mode (all-Surya, all-local) and Cloud mode
(Claude as cascade tail + table extractor + cleanup) are both
first-class, switchable from a top-level Settings toggle. Surya
is **not** removed — it remains the default and the offline
guarantee for sensitive material.

The user picks `Processing Mode: Private | Cloud` once; per-feature
toggles inside Cloud mode (hard-region OCR, table extraction,
post-OCR cleanup, semantic classification, TOC parsing) gate
individual Claude calls and let the user dial cost up or down.

## Per-feature model selection

| Feature | Model | Why |
|---|---|---|
| Hard-region OCR (Cloud cascade tail) | Sonnet 4.6 | Trusted as ground truth; multilingual + ancient scripts demand the strongest visual reasoning |
| Table extraction (replacing Path A) | Sonnet 4.6 | Spatial reasoning + structure understanding; tables are rare per book so cost is bounded |
| Post-OCR character cleanup | Haiku 4.5 | Targeted edits (ligatures, diacritics, long-s); no need for Sonnet |
| Semantic chapter classification | Haiku 4.5 | Tiny prompt, closed label set, ~per-chapter |
| TOC parsing | Haiku 4.5 (Sonnet escalation if quality bad) | One call per book, ~$0.001 either way |

Mental model: **Haiku for "polish / classify text we already
have," Sonnet for "look at this image and produce ground-truth
content."**

## Cloud-migration phase status

| Phase | What | Status |
|---|---|---|
| 1 | Anthropic API plumbing (`AI` library: client + transport + key store + settings + Settings UI) | **Done** (commit `567d2c3`) |
| 2 | `ProcessingMode` plumbed end-to-end into `PDFToEPUBPipeline.Options` + `JobRunner`; dispatch switches added at engine sites | **Done** (commit `0e00a76`) |
| 3 | `ClaudeOCREngine` (Sonnet vision) wired in as the cascade's high-quality tier under `.cloud` | **Done** (commit `9a4adfd`) |
| 4 | Validation spike: CER comparison vs Surya / Tesseract on hand-corrected ground truth (polytonic Greek) | **Done** — Local 15.1% / Cloud cascade 15.1% / Claude-only 11.3% (commit `9a4adfd`) |
| 5 | `ClaudeTableExtractor` (Sonnet) behind a `TableExtractor` protocol; Surya path stays as offline fallback | **Done** |
| 6a | Post-OCR Haiku cleanup — passages mode (text-only) | **Done** (commit `c6564bd`) |
| 6b | Post-OCR Haiku cleanup — vision mode (multimodal) | **Done** (commit `ae99693`) |
| 6c | Correction trail sidecar + interactive editor sheet (apply / revert) | **Done** (commit `f91d0e0`) |
| 6d | Semantic chapter classification (`epub:type` per chapter, Haiku) | **Done** (commit `e985946`) |
| 6e | Printed-TOC parsing (Haiku, Sonnet escalation if needed) | **Done** (commits `bd466f3`, `e3eb46c`) |
| 7 | First-run UX polish (Cloud-upgrade prompt, README docs) | **Done** (commit `e42253f`) |
| Page-OCR | Whole-page Sonnet OCR pathway (parallel to the cascade) | **Done** (commits `569c421`, `cba7f64`, `0130e34`) |
| 8 | (Deferred) Per-book mode override for sensitive material when default is Cloud | Largely covered by Private Mode (commit `8442e37`); formal per-book persistence still deferred |

Phases 1–2 ship the foundation; everything else is incremental
on top of that infrastructure. The `AnthropicAPIClient`,
Keychain store, Settings UI, and `ProcessingMode` dispatch
points are reused unchanged across phases 3–6.

The detailed design docs for the three Haiku features predate
the hybrid-architecture decision but remain architecturally
valid — they describe the prompt shape, guardrails, and editor
trail. The entries below summarize each. Phase-3 ClaudeOCREngine
absorbs what was originally P-LLM-Pass's "vision mode";
P-LLM-Pass's "passages mode" is what becomes the Cloud Phase 6
post-OCR cleanup feature.

---

## P-LLM-Pass — Post-OCR character cleanup (Cloud Phase 6, Haiku)

**Status**: shipped — passages mode (commit `c6564bd`), vision
mode (commit `ae99693`), and the interactive correction-trail
editor sheet (commit `f91d0e0`). The implementation matched this
plan closely; one notable simplification is that we reused the
existing `OCRChangeGuardrail` (designed for the OCR cascade) for
post-OCR vetting rather than building a separate
`ChangeGuardrail`. Apply / revert in the editor uses
whitespace-tolerant find-and-replace with graceful fallback when
the OCR-stage text didn't survive reflow byte-for-byte; full
XHTML-aware replacement is deferred until that fallback proves
inadequate in practice.

The original design notes below are kept for reference.

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

## P-Semantic-Classification — per-chapter `epub:type` tagging (Cloud Phase 6, Haiku)

**Status**: shipped (commit `e985946`). `EnglishRegexClassifier`
ships as the offline fallback; `ClaudeHaikuClassifier` is the
Cloud-mode path for multilingual headings (Préface / Vorwort /
Praefatio / ΠΡΟΛΟΓΟΣ). Wired into `ChapterSplitter` output;
EPUB writer emits per-chapter `<section epub:type="…">` and a
landmarks `<nav>`. Full design history at
[Plans/Phase2-Semantic-Classification.md](Plans/Phase2-Semantic-Classification.md).

### Goal

Tag each chapter produced by `ChapterSplitter` with an EPUB 3
Structural Semantics Vocabulary role (`preface`, `introduction`,
`chapter`, `bibliography`, `index`, `appendix`, etc.). Surface
those roles to readers via per-chapter `<section epub:type="…">`
wrappers and an EPUB 3 `<nav epub:type="landmarks">` so navigation
panels show "Bibliography" / "Index" as direct jump targets the
way commercially-published EPUBs do.

### Backend choice

Two implementations behind a `SemanticClassifier` protocol:
- **`EnglishRegexClassifier`** — always available. Pattern table
  for common English roles. Fallback when no API key.
- **`ClaudeHaikuClassifier`** — handles multilingual headings
  (French "Préface", German "Vorwort", Latin "Praefatio", Greek
  "ΠΡΟΛΟΓΟΣ"). Uses the API client + Keychain plumbing P-LLM-Pass
  ships first.

The Phase 2 design doc also covers an Apple Foundation Models
backend variant (macOS 26+, no key, no network, no cost) as a
mutually-exclusive alternative to Claude Haiku. Pick one based on
the macOS-version target.

### Key reuse from P-LLM-Pass

- Anthropic `URLSession` wrapper
- Keychain-backed `AnthropicAPIKeyStore`
- Settings pane (extends with one toggle: "Use Claude for chapter
  classification")
- Failure / fallback pattern (silently fall back to regex on
  network or key absence)

### Effort estimate

~2.5 days when P-LLM-Pass has shipped first (~3.5 days standalone,
per the existing design doc — most of the savings is the shared
API plumbing).

### Risks

Same as P-LLM-Pass: hallucinated labels, key leakage, rate
limits. Validation against a closed role set catches the first;
Keychain handles the second; the per-book cost cap (also shared)
handles the third.

---

## P-TOC-Parsing — Parse the printed TOC into an authoritative tree (Cloud Phase 6, Haiku)

**Status**: shipped (commits `bd466f3`, `e3eb46c`). `TOCDetector`
+ `TOCExtractor` + `ClaudeTOCParser` produce a structured TOC
tree with printed page numbers; `nav.xhtml` is driven by the
parsed TOC when one is available, and TOC-derived chapter titles
override Surya's heading reads. Full design history at
[Plans/Phase3-TOC-Parsing.md](Plans/Phase3-TOC-Parsing.md).

### Goal

When a book has a printed table of contents (most academic and
commercial books do), extract it, parse it into a structured
tree of entries with their printed page numbers, then use it as
the authoritative source for chapter / section / subsection
structure. Beats heading-detection alone because:
- TOCs encode hierarchy (Part → Chapter → Section)
- TOCs have authoritative titles even when Surya OCR'd the
  page-1 heading wrong
- TOCs map sections to printed page numbers, which combined with
  our per-page anchors give us reliable "Chapter 3 starts on PDF
  page N" links

### Pipeline

1. **`TOCDetector`** — find TOC pages via PDF outline (free if
   present), text scan ("Contents" / "Sommaire" / "Inhalt"), or
   layout-shape heuristic.
2. **`TOCExtractor`** — render + Surya OCR the detected TOC pages.
3. **`ClaudeTOCParser`** — send TOC text to Claude with a
   structured prompt, get back a JSON tree of `{title, page,
   level, type}` entries. Falls back to a regex parser when no
   API key.
4. **`PrintedPageMap`** — map printed page numbers (TOC's
   reference) to PDF page indices (our internal coordinate)
   using the page-number observations we already detect.
5. **`TOCAlignedChapterSplitter`** — replaces the heading-based
   `ChapterSplitter` from Phase 1 when a parsed TOC is available.
   Uses TOC-derived chapter boundaries + authoritative titles.

### Key reuse from P-LLM-Pass + P-Semantic-Classification

- Same `URLSession` / Keychain plumbing.
- Same Settings pane (extends with another toggle: "Use Claude
  for TOC parsing").
- Same fallback pattern.
- The parsed TOC's `type` field can supersede
  P-Semantic-Classification's per-chapter classification when
  both run (TOC wins; classifier picks up unmapped chapters).

### Failure-mode hierarchy

The system degrades gracefully (per the existing design doc):
1. **Best**: PDF outline + Claude parse + complete page map →
   fully aligned chapters with hierarchy.
2. **Good**: text-scan TOC + Claude parse + partial page map →
   chapters aligned to TOC but some titles missing.
3. **Acceptable**: TOC found, parse fails / no API key →
   heading-based splitting (Phase 1 default).
4. **Fallback**: no TOC → single chapter or heading-based
   splitting.

The user always gets a valid EPUB.

### Effort estimate

~7-8 days standalone (per the existing design doc), ~6 days when
the API client / Keychain / Settings pane are already in place.

### Risks

Per the existing design doc:
- Hallucinated TOC entries (validation step + monotonic-page check)
- OCR'd TOC pages garbled (gate on Surya, fall back gracefully)
- Printed-page resolution failure (interpolation + fall back)
- Cost runaway (one call per book, ~$0.001 — trivial)

---

# Tier 3: Language + corpus expansion

## P9 — RTL languages: Hebrew, Syriac, Coptic

**Status**: deferred indefinitely. Architecture supports adding
them, but the user's working corpus doesn't need them often
enough to justify the bidi rendering edge cases + per-script
Tesseract weaknesses. Design notes below kept for reference if a
Hebrew / Syriac / Coptic project ever comes up.

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

## R-Launcher-Pause — Pause / Resume Queue control

**Status**: shipped. `JobRunner.pause()` / `resume()` toggle a
soft-pause flag the run loop checks between jobs — the
currently-running job finishes; subsequent `.queued` jobs stay
queued until the user resumes. Persisted via `UserDefaults`
(`humanist.queuePaused`) so a "come back later" pause survives
app restart. Bottom-bar Pause / Resume button (icon flips
between `pause.fill` and `play.fill`) sits between Choose Files
and Cancel All; visible whenever there's pending work or the
queue is currently paused. New `HumanistTests` target with 8
JobRunner state-machine tests (default state, pause / resume /
idempotence, persistence across runner instances, start no-op
while paused).

## R-Launcher-History — Completed-jobs disclosure

**Status**: shipped. Queue list now splits into two sections:
active jobs (queued / running / profiling) at the top with
reorder; finished jobs (done / failed / cancelled) under a
collapsible "History (N)" `DisclosureGroup` at the bottom,
sorted most-recent-finish first. Defaults collapsed so a long
bulk run doesn't push the active queue off-screen; the user
expands it to inspect past results, retry failures, or open a
past EPUB. Existing JobRow actions (open, retry, etc.) work
identically inside the disclosure — no per-row code changes
needed. The existing on-disk JSON store already persists across
launches, so history survives app restart for free.

New `JobStore.activeJobs` / `JobStore.finishedJobs` computed
properties are the partition surface; 5 tests cover filter
correctness, recency sort, nil-`finishedAt` handling, and
disjoint coverage of every job status.

## R-Launcher-Reorder — Drag-reorder queued jobs

**Status**: shipped. New `JobStore.move(from:to:)` delegates to
`Array.move(fromOffsets:toOffset:)` and persists. Queue list
swapped from `LazyVStack` → `List` so SwiftUI's `.onMove` is
available; visual cards preserved via `.listRowBackground` +
clear separators + zeroed insets + `.scrollContentBackground(.hidden)`.
List ships a hover-drag handle on macOS, so no custom affordance
needed.

Reorder is unrestricted: dragging a non-queued job (running /
done / cancelled) just permutes the array — the runner still
picks first `.queued` regardless, so the user-visible effect is
display-only. Letting users reorder freely beats imposing
per-row drag-eligibility rules that would surprise them. 5 new
JobStoreTests cover basic reorder, promote-to-front, empty-
indexset no-op, persistence across store instances, and mixed-
status reordering.

## R-Launcher-FullQueue — Dedicated full-queue window

**Status**: not started. The launcher's queue list scrolls but
its visible area is bounded by whatever window size the user has
on the launcher. After a bulk drop of 50 PDFs, the user wants to
see the whole queue at once — status, progress, language, cost
estimate per row, all together — without the launcher's drop
zone, options, and bottom bar competing for vertical space.

### Approach

- New `WindowGroup` (or `Window`) scene with id `"queue"`. Single
  instance — opening it twice reuses the existing window. Title
  "Humanist Queue".
- Density-optimized table rendered with `Table` (SwiftUI) or
  `List`. Columns: status icon · filename · status text /
  progress · detected language · cost estimate · actions
  (Cancel / Retry / Reveal). Sortable by column, optionally
  filterable.
- Scrolls independently of the launcher window — designed to
  hold hundreds of rows without compromising the launcher's
  drop / options surface.
- Window > Show Full Queue command (⇧⌘Q) opens it; also a
  toolbar / menu link from the launcher's bottom bar.

### Effort

~1 day. The job-row presentation logic is mostly reusable from
the existing `JobRow` (just rendered in a denser layout). Most
of the time goes into the Table column setup + the new scene.

### Dependencies

None hard. Plays well with R-Launcher-Pause / -History /
-Reorder; doing those first means the full-queue window inherits
their controls cleanly.

## R-Conversion-Summary — Post-conversion stats panel

**Status**: shipped (commit `e17cde8`). `ConversionStats` now
flows out of `PDFToEPUBPipeline.convert()` and is persisted on
each `Job`; the queue UI surfaces Claude calls + approximate cost
per row. Cost rates live in the `AI` module's per-model rate
table; `≈` prefix communicates these are estimates.

The Phase 4 spike made this gap concrete: a user with Cloud mode
on can't tell if the cascade actually escalated to Claude on a
given book. That's friction we can remove cheaply, and it's a
prerequisite for the broader AI trail inspector planned in Cloud
Phase 6.

### Goal

After every conversion, surface a small summary so the user
knows whether Cloud mode actually did anything. Specifically:

- Claude calls (Sonnet for OCR + table extraction, Haiku for
  cleanup / classification / TOC) — count + approximate cost.
- Per-source observation breakdown (Vision / Tesseract / Surya /
  Claude / embedded-text) so the user can see *which tier* the
  output mostly came from.
- Visible in the queue UI as a per-job row (or expandable
  disclosure) so the user can scan a bulk run and see at a glance
  which books leaned on Cloud features.

### Approach

```
Pipeline/
├── ConversionStats.swift          NEW. Sendable, Codable struct.
│                                  Per-source obs counts, Claude
│                                  call count, approximate cost.
└── PDFToEPUBPipeline.swift        convert() returns ConversionStats
                                   (was Void). Read counter from
                                   `ClaudeCallBudget.consumed`.

Humanist/Jobs/
├── Job.swift                      Add `stats: ConversionStats?`
│                                  field, persisted in queue store.
└── JobRunner.swift                Capture stats from convert(),
                                   write back via store.update().

Humanist/                          New row / column in the queue
                                   UI. "Claude: 12 calls (~$0.06)"
                                   when N > 0; "Claude: not invoked"
                                   when N == 0.
```

1. `ConversionStats` carries the counters. `Codable` because it
   gets persisted with the `Job` (the queue store round-trips
   jobs through JSON).
2. Cost estimate is a small per-model rate table living in the
   `AI` module (Sonnet + Haiku input/output rates). The stats
   struct stores token totals when known and a derived dollar
   estimate. Honest "≈" prefix in the UI — these are estimates,
   not invoice numbers.
3. The reOCR single-page path (editor) returns a stats struct too
   so the editor can show "this re-OCR cost ~$0.01 / used Claude
   / used Tesseract" inline.

### Effort

~1 day end-to-end:
- ~2 hours: stats struct + `convert()` return-type plumbing
- ~2 hours: queue UI changes
- ~1 hour: per-model rate table + cost helper
- ~1 hour: tests
- ~2 hours: edge cases (jobs persisted before stats existed →
  nil; cancelled jobs; JobStore JSON migration if needed)

### Dependencies

None hard. `ClaudeCallBudget.consumed` already exposes the
underlying signal from Phase 3.

### When to ship

Now-ish. Queues naturally before the AI trail inspector (Cloud
Phase 6) — the inspector needs stats infrastructure anyway, and
the spike confirmed that "user can't tell if Claude fired" is a
real friction point, not hypothetical.

---

## R-Footers — Cross-page running-footer recurrence

**Status**: shipped. `classifyTopRegionsByRecurrence` is now a thin
wrapper over `classifyEdgeRegionsByRecurrence(zone:)`, which runs
once for each edge zone. Top zone preserves the existing two-way
behavior (recurring → `.pageHeader`, unique → `.sectionHeader`).
Bottom zone is symmetric on the recurring side only — recurring
text in the bottom 15% becomes `.pageFooter`; unique short
bottom-of-page strings stay as `.text` (a unique string at the
bottom is more likely a footnote stub or decorative line than a
section break, so we don't promote there). Top + bottom override
maps merge before the per-page passes; both zones contribute to
the cross-page audit trail surfaced in the debug log.

### Goal

Apply the same cross-page recurrence logic to the bottom zone so
recurring "Stoicheia I.iii" or chapter-bottom labels get tagged as
`.pageFooter` instead of `.text`.

---

## R-Hierarchy — Multi-level chapter / section / part structure

**Status**: shipped. New `ChapterHierarchy` helper in the EPUB
target walks each chapter for headings deeper than the chapter's
own opening heading and assigns each one a stable
`hu-sec-{chapterIdx}-{blockIdx}` id. `XHTMLWriter` emits those ids
on the rendered `<hN>` elements; `EPUBBuilder.makeNavEntries`
threads them as nested `NavWriter.Entry.children`. `NavWriter`
renders the children as a child `<ol>` inside the chapter's
`<li>`, recursively (H2 → H3 → H4 nests three deep). Heuristic-
chapter path only — the parsed-TOC path stays flat because
`ParsedTOC.Entry` doesn't carry per-entry levels yet (a follow-up
to the TOC parser, not R-Hierarchy).

Mis-nested branches (a deeper heading appearing before any
shallower one in the chapter) attach to the chapter root rather
than getting dropped — better to surface a slightly mis-leveled
entry than lose it from navigation entirely.

### Goal

Detect a hierarchy (Part → Chapter → Section → Subsection) from
H1 / H2 / H3 boundaries and emit a nested EPUB nav.

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

**What's already done** (so they're off the runway):
- **Tier 1**: figures, tables (Surya `TableRecPredictor` + Claude
  Sonnet + heuristic fallback), math (figure raster path).
- **Tier 1.5**: `P-Lang-Detect`, `P-Cloud-Cost`, `P-Profile-Warnings`
  — full pre-flight pipeline.
- **Cloud Phases 1–5**: Anthropic API plumbing, Keychain key store,
  Settings UI, `ProcessingMode` plumbed end-to-end, `ClaudeOCREngine`
  wired into `RegionCascade` as Stage 3, polytonic-Greek validation
  spike, `ClaudeTableExtractor` behind a `TableExtractor` protocol
  with Surya as the offline fallback.
- **Cloud Phase 6 (all sub-phases)**: post-OCR cleanup (passages +
  vision), correction-trail editor sheet, semantic chapter
  classification, printed-TOC parsing.
- **Cloud Phase 7**: first-run welcome sheet + README rewrite.
- **Whole-page Claude OCR pathway** (`useClaudePageOCR`): one
  Sonnet call per page → structured XHTML → `[Block]` +
  `[Footnote]`. Now the user-visible "Claude OCR ($$$)" toggle.
- **R-Conversion-Summary**: per-job Claude call + cost surfaced
  in queue UI.
- **Private Mode toggle**: per-conversion Cloud override that
  guarantees zero Claude traffic.
- **Editor**: format/insert/edit menus, Special Character, Goto
  Line, Split / Merge / Regenerate TOC, Find in All Files,
  Validate EPUB (epubcheck), spellcheck, smart quotes,
  formatting toolbar.

**Next, in roughly this order:**

1. **Launcher quality-of-life** — `R-Launcher-Pause`,
   `R-Launcher-History`, `R-Launcher-Reorder`, `R-Launcher-FullQueue`
   in whatever order the user reaches for first.
2. **Editor / library polish** — `R-Search`, `R-Custom-Styles`,
   `R-Library`, `R-Bulk-Editor` in whatever order matches actual
   working friction. None are load-bearing; pick them up as the
   need arises.
3. **Defer Phase 10 (distribution)** until the user actually wants
   to share or onboard another machine. The app is signed and runs
   locally; that's enough for personal use.

Phase 9 (RTL / Hebrew / Syriac / Coptic) is deferred indefinitely
— corpus doesn't justify the bidi-rendering and per-script
accuracy lifts. The originally planned hybrid Cloud feature set
is now complete; what remains is launcher + editor polish for
the working flow.
