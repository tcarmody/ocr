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

## Status snapshot (as of 2026-05-11)

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
- Italic/bold preserved through run reconstruction: per-word
  font attributes from Tesseract (`WordFontAttributes`), Vision
  italic/bold flags, and typographic heading-cue heuristics all
  flow through to `InlineRun.isItalic` / `isBold` in the final
  output XHTML (commits `e74aa21`, `7aa35a6`, `f761e6a`).
- Page-OCR robustness: downsize pages to fit Anthropic's 5 MB /
  8000 px limits before sending (commit `37c6286`); fall back to
  local Vision OCR when Sonnet refuses or errors on a page
  (commit `4dc1e45`).
- **V-PDF-Searchable** (commit `30a9486`): "Searchable PDF"
  toggle in the launcher emits `<basename>.searchable.pdf`
  alongside the EPUB — source PDF re-rendered with an invisible
  OCR text overlay per observation. No extra OCR cost (reuses
  the pipeline's `TextObservation` arrays). Routes to the
  configured output folder's `Books/` subfolder when set.
- **V-Refresh — Re-OCR All Pages** (commits `991b1bb`,
  `0025c5b`): Document menu → "Re-OCR All Pages With ▸ {engine}"
  walks every page-map entry, re-renders the matching PDF page,
  reflows via the standard pipeline, and splices the result
  between `hu-page-N` anchors using `PageContentReplacer` (a
  Swift port of the CodeMirror splice logic). v2 preserves
  manual edits made in the XHTML between re-OCR pages — partial
  runs keep forward progress. Disabled without an attached source
  PDF + page-map sidecar.

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
- **App-wide theme system** (commits `a13ebaa`, `85c431d`,
  `c034c6c`): five named palettes — System, Parchment, Scholarly,
  Nocturne, Studio — switchable from Settings → Appearance.
  `HumanistThemeStore` singleton propagates palette changes
  across all windows at draw time via dynamic `NSColor` values;
  each theme defines its own light + dark variant.
- **Configurable output folder** (commit `911eb7d`): Settings →
  Conversion tab lets the user pick a root folder; conversions
  route artifacts into per-format subfolders (`Books/`, `Text
  Files/`, `Markdown/`, `HTML/`). `ConversionOutputResolver`
  computes target URLs; the pipeline receives per-format override
  URLs so it stays folder-agnostic. `EPUBBuilder` embeds the
  source PDF's absolute path in the Humanist sidecar so the
  editor finds it even after moving the EPUB.
- **Non-PDF input formats** (commits `7353d33`, `0ed2b72`):
  drop a `.txt`, `.md`, `.rtf`, `.html`, `.doc`, `.docx`, or
  `.odt` onto the launcher and it converts to EPUB via
  `DocumentIngest` — no OCR, no Surya, no Claude. Headings, bold,
  italic survive via `NSAttributedString` paragraph styles and
  font traits. Lists, tables, and images flatten to prose in v1.
  Sibling `.txt` / `.md` / `.html` still emit; library catalog
  and output-folder routing apply identically to the PDF path.
- **File Tools menu** (commit `6afa73a`): four file-system
  utilities (no editor window required) — PDF Join, PDF Split,
  EPUB Join, EPUB Split. PDF operations use PDFKit + the existing
  `PageRangeParser` syntax. EPUB Join merges N EPUBs under
  per-book subdirectories (source #1 metadata wins; title
  overrideable). EPUB Split writes one EPUB per chapter range,
  copying only images referenced by each part.

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
- **Save-on-close dialog**: `WindowSaveGuard` replaces the old
  `WindowDirtyBridge`; intercepts `windowShouldClose` and
  presents Save / Discard Changes / Cancel when the document is
  dirty. Save is async — fires the save pipeline then
  programmatically closes the window on success.
- **WYSIWYG formatting oscillation fix**: toolbar commands
  wrapped in `WYSIWYGCommandRequest` carrying a UUID nonce. The
  coordinator tracks `lastAppliedCommandID` and skips re-applying
  the same click if `updateNSView` fires again before the async
  `commandRequest = nil` lands — previously caused toggle-based
  commands (blockquote, bold, superscript) to fire twice and
  oscillate.
- **Source → WYSIWYG sync on save**: `EditorViewModel` emits
  `wysiwygReloadToken` after every successful save. `WYSIWYGView`
  compares it against `lastSeenSaveToken` and reloads if the
  body text in `xhtml` differs from `lastLoadedBodyHTML`. Fixes
  the bug where source-pane edits would be silently overwritten
  the next time the user typed in the WYSIWYG pane.
- **Pane divider visibility**: a 2 pt `separatorColor` accent
  overlaid on the leading edge of every non-first pane makes the
  NSSplitView dividers visually distinct.
- **Equalize Panes**: View menu command (and right-click context
  menu on any pane header) calls `PaneEqualizerBridge`, which
  walks up to the `NSSplitView` and calls
  `setPosition(_:ofDividerAt:)` for each divider to distribute
  all visible panes equally.
- **Footnote Manager** (Insert › Footnote Manager…): two-tab
  sheet. "Existing" tab lists `<aside epub:type="footnote">`
  elements already in the chapter. "Scan" tab detects unlinked
  `<sup>N</sup>` callsites matched against end-of-chapter
  numbered paragraphs; per-pair "Apply" buttons rewrite both
  callsite (wraps in a noteref anchor) and definition (wraps in
  an aside) into valid EPUB 3 footnote markup.
- **Chapter Manager** (Document › Chapter Manager…): panel
  listing all spine chapters in reading order with filename,
  inferred title, `epub:type` picker (20 standard values), and
  Up / Down reorder buttons. Editing `epub:type` writes directly
  to the chapter's XHTML buffer via `writeChapterText(_:to:)`.
  Clicking a title jumps to that chapter in the editor.
- **WYSIWYG editor pane** (commits `5418a38`, `275820d`,
  `8fc0498`, `32668d4`, `6af5d14`): fourth editor pane (⌘4)
  backed by a `WKWebView` with `contenteditable`, rendering the
  chapter via the book's own CSS. Formatting toolbar mirrors the
  source pane's button set; `document.execCommand` handles
  bold/italic/headings/blockquote/lists; custom DOM passes handle
  inline `<code>`, language spans, and smart quotes. Edits
  debounce 250 ms then push the serialized body back into
  `vm.sourceText`; void elements and `<b>`/`<i>` are sanitized
  to XHTML/`<strong>`/`<em>` on the way out. Appearance settings
  (font family/size/theme) from Settings propagate live via CSS
  variables without a page reload.
- **Chat-with-book pane** (commits `b26a09c`, `fee27ee`,
  `3d273df`): fifth editor pane (⌘5, Cloud-only). BM25 keyword
  retrieval picks the top 4 chapters as context for each query;
  Haiku (default) or Sonnet (Settings toggle) answers with
  inline `[chapter:N]` citations that render as clickable chips
  below each message. Streaming responses via SSE. Per-EPUB
  transcript persisted to `META-INF/com.humanist.chat.json` so
  conversations survive close/reopen. Clear button in the pane
  header deletes the transcript.
- **Drag-and-drop chapter reorder** in the sidebar (commit
  `3ae82ec`): drag any spine chapter onto another row to move it
  to that slot. `EPUBBook.moveInSpine(id:toIndex:)` handles
  arbitrary-position moves (vs. the existing ±1 `direction:`
  API). Non-spine items don't participate.
- **Rename Chapter with link rewriting** (commit `35f45cd`):
  right-click a chapter → "Rename Chapter…" prompts for a new
  filename stem. `LinkRewriter` walks every other text resource
  and rewrites `href`/`src` attributes resolving to the old path
  (same-directory, cross-directory, and fragment-bearing links
  all handled). `EPUBBookSaver` moves the file + rewrites
  siblings atomically. Editor remaps its URL-keyed buffer state
  to the new path on completion. 22 unit tests.
- **Sibling regeneration on save** (commit `7913828`):
  `SiblingRegenerator` rewrites existing `.txt` / `.md` / `.html`
  siblings whenever the editor saves the EPUB — keeps
  non-EPUB consumers of the book in sync with the latest
  post-edit source. Best-effort; only regenerates siblings that
  already exist next to the EPUB (or in the configured output
  folder), so the user's "no siblings" preference is preserved.
- **HTML sibling output** (commit `1a89bd5`): `HTMLWriter` emits
  `<basename>.html` alongside `.txt` and `.md` for every
  conversion — a single self-contained HTML5 document (inline
  CSS, no external assets) with one `<section>` per chapter.
  The launcher's toggle now reads ".txt + .md + .html" and
  controls all three. Lands in `HTML/` when an output folder is
  configured.

**Done — Distribution prep (Phase 10 partial)**:
- **Setup wizards for external dependencies** (commits `4e5163c`,
  `f91258d`, `bbea813`): rather than bundling Python + PyTorch +
  Surya weights (~1.8 GB), the .app ships at ~14 MB and walks the
  user through installing dependencies on first launch. Three
  wizards mirror the same three-step flow:
  - **Surya** (`SuryaSetupSheet`) — `uv tool install surya-ocr`,
    ~1 GB. Banner on the launcher when not installed; pipeline
    falls back to Vision-only OCR.
  - **Tesseract** (`TesseractSetupSheet`) — `brew install tesseract
    tesseract-lang`, ~150 MB. Contextual badge that only surfaces
    when the user's language selection would benefit.
  - **Ollama + Gemma 4 26B MoE** (`OllamaSetupSheet`) — local chat
    backend, ~18 GB. Optional; chat defaults to Cloud (Haiku).
  Each wizard offers a Skip option that's always honored.
- **Pinned Developer ID signing** (commit `8abae61`):
  `Scripts/build-app.sh` now pins to a specific Developer ID hash
  rather than relying on `security find-identity` heuristics that
  break with multiple matching certs. Hardened-runtime + timestamp
  + deep flags added so the build is notarization-ready when a
  proper Developer ID Application cert is available.
- **`humanist-cli` executable** (commit `468b4d6`): full CLI
  exposing `convert`, `compare`, `validate` subcommands. Same
  Pipeline / EPUB / AI engines as the app; ~5.9 MB binary; uses
  `swift-argument-parser`. All input formats (PDF / TXT / MD /
  RTF / HTML / DOCX / DOC / ODT) and all output formats (epub,
  md, txt, html, docx, searchable-pdf) supported via `-f`.
  Per-feature Cloud toggles individually disableable. JSON
  output mode for CI. Reads API key from `$ANTHROPIC_API_KEY`.
  See `Sources/HumanistCLI/README.md` for the full surface.
- **`RELEASES.md`** (commit `e920612`): operational walkthrough
  for cert generation, hardened-runtime signing, `notarytool`
  workflow, DMG assembly, GitHub Releases, optional Sparkle
  auto-updates, and the clean-Mac smoke test.

**Done — Swift 6 strict concurrency mode** (`C-Swift6-Migration`,
in Tier 6 — full write-up there):
- `Package.swift` is at `swiftLanguageModes: [.v6]`; the 822-test
  suite passes clean.
- Partial cleanup landed earlier in commit `abaa918`
  (`DocumentProfiler.lastSamples` deleted; `TwoUpDetector`
  refactored to a `Detection` return struct; `SidecarBridge` wire
  format moved to `Data` for Sendable-clean cross-actor IPC).
- The rest of the migration (this round) cleared
  `RegionAwareReflow`'s 8 debug statics into a `Diagnostics`
  return struct, made `DOCXWriter`'s NSFont/NSAttributedString
  constants computed, marked `LoadedPDF: @unchecked Sendable` with
  a defended invariant, restructured `PDFToEPUBPipeline`'s
  TaskGroup closures to use captured method references plus a
  PDF snapshot, and fixed `QueueViewModel`'s `runner` capture and
  `supportedLanguages` isolation. Cascade Sendable conformances
  on `EmbeddedTextExtractor`, `EmbeddedTextQualityScorer`, and
  `FigureExtractor`. One audited `nonisolated(unsafe)` for the
  deinit-only `pdfPageObserver` token in `EditorViewModel`.

**Done — Local chat backend**:
- **Ollama + Gemma 4 26B MoE** (commit `bbea813`): chat-with-book
  pane gains a third backend alongside Cloud Haiku/Sonnet.
  `OllamaClient` (HTTP, non-streaming, 300 s timeout) hits
  `localhost:11434/api/chat`; `ChatBackend` enum drives Settings →
  AI picker. No API key, no per-token cost, no network egress.
  Default model `gemma4:26b` (~18 GB, ~20 GB RAM, ~25 tok/s on
  Apple Silicon, 256K context). The "Book Chat" Settings section
  moved outside the cloud-only conditional so a Private-mode user
  can configure local chat without flipping their global mode.

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
- Phase 10 — Distribution polish. Setup wizards (Surya / Tesseract /
  Ollama) ship in lieu of bundled runtimes, and the build script is
  notarization-ready, but the actual Developer ID cert + DMG
  hosting + Sparkle auto-updates are still pending. See `RELEASES.md`
  for the full operational walkthrough.

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

**Status**: shipped. New single-instance `Window` scene with id
`"queue"` (opening when already open just brings it to front).
Title "Humanist Queue". Hosts a SwiftUI `Table` with sortable
columns: status icon · filename · status text / progress ·
detected language · cost · actions (Cancel / Retry / Open /
Reveal / Remove). Defaults to arrival-order sort to match the
launcher.

`Window > Show Queue` menu command (⇧⌘Q) and a "Show Queue"
button in the launcher's bottom bar (visible whenever the queue
has any rows) both open the window. The launcher and the queue
window share the same `JobStore` / `JobRunner` env objects, so
edits in either reflect immediately in the other — pause /
reorder / history all work identically through both surfaces.

7 new sort-key tests cover `Job.Status.sortRank` (active states
before resolved, stable per value) and `Job.costSortKey`
(prefers actual stats over estimate, falls back to estimate
when no stats, zero in three "neither / empty / no Claude calls"
permutations).

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

**Status**: shipped. New `Tools > Customize Style…` sheet lets
the user pick font (serif / sans / monospace), size (0.75–1.5em
slider), and theme (light / sepia / dark). Apply regenerates the
EPUB's `OEBPS/css/book.css` through the existing dirty-buffer
pipeline so Save flushes the change into the .epub; the preview
pane reloads on the same `previewVersion` bump that other edits
use. The user's choices round-trip across save / reopen via a
sentinel JSON comment (`/* humanist-style: {...} */`) embedded
in the CSS — no separate META-INF sidecar needed.

User-authored CSS rules above the sentinel block are preserved;
the `humanist-style:start … end` markers carve out exactly the
override block so consecutive applies replace it cleanly without
stacking. Out-of-range font sizes clamp to 0.5–2.0em so a
corrupted value can't produce unreadable output.

9 new BookStyleTests cover sentinel emission, user-CSS preservation,
single-block round-trip across re-applies, parse-recovery for every
font × theme × size combination, malformed-sentinel rejection, and
the size-format / theme-palette helpers.

---

## R-Search — Full-text search in the editor

**Status**: shipped as Find in All Files (commit `baea472`).
Cross-chapter search + replace + go-to-source via a dedicated
sheet (⇧⌘F). Hits show file + line + context, click jumps to
the source pane and scrolls / flashes the match.

---

## R-Library — Library browser window

**Status**: shipped. New `LibraryStore` (JSON-backed, persisted
at `~/Library/Application Support/Humanist/library.json`)
records every successful conversion with title, language list,
addedAt, and lastOpened. New single-instance Library window (id
`"library"`, ⇧⌘L, "Show Library" menu command in Window menu)
hosts a SwiftUI Table with sortable columns (Title, Languages,
Added, Last Opened, Actions) and a per-language filter picker.
Click → opens in editor and bumps lastOpened; right-click →
Open / Reveal in Finder / Remove from Library. Removing only
forgets the row — the .epub stays on disk.

`JobRunner` records on the success path (via a new optional
`library: LibraryStore?` init parameter); `OpenRouter.open`
bumps lastOpened on EPUB-shaped routes. Re-converting to the
same EPUB updates title + languages in place rather than
duplicating; original `addedAt` is preserved. Files that no
longer exist on disk are pruned on next load (same posture as
`RecentsStore`).

Cover-image thumbnails shipped (commit `f71318e`). `CoverExtractor`
reads only the OPF + cover-image entry from the EPUB ZIP (no full
unpack); decodes lazily at 240 px max via ImageIO and caches in
`CoverImageCache` for the app session. Handles both EPUB 3
(`properties="cover-image"`) and EPUB 2 (`<meta name="cover">`).
Each Library row shows the thumbnail next to the title.

8 new LibraryStoreTests: record-conversion, dedup-by-URL with
addedAt preservation, recordOpen no-op for unknown URLs, JSON
persistence round-trip, missing-file pruning on load, and
remove-without-deleting-file.

---

## R-Bulk-Editor — Bulk editor operations

**Status**: shipped (v1: cross-book find/replace).
`BulkEditor.replace(in:query:replacement:caseSensitive:regex:progress:)`
opens each EPUB into a temp working tree, runs
`PackageSearch.replaceAll` over every text file, writes changes
back to disk, and repacks the .epub in place via `EPUBRepacker`.
Per-book results carry replacement counts plus an optional error
field — failures on one book don't abort the batch. Books with
zero matches skip the repack entirely so unchanged EPUBs aren't
touched (mtime preserved, backups preserved).

UI: multi-select rows in the Library window's Table, then
"Bulk Edit Selected…" in the filter bar opens a sheet with
Find / Replace / case-sensitive / regex controls + per-book
progress + a results list (✓ / no-matches / error). Apply runs
on a detached Task so the unpack/repack cycle doesn't block
the main thread.

Re-OCR-by-language across books is intentionally deferred —
that re-engages the conversion pipeline and is a separate
feature. v1 covers the higher-utility cross-book find/replace
piece.

6 new BulkEditorTests against real EPUB fixtures built via
`EPUBBuilder`: full open → search → replace → repack
round-trip, no-match repack skipping (mtime-preserved),
per-book error isolation when one URL is bogus, empty-query
no-op, case-sensitivity flag, and per-book progress callback.

---

# Tier 6: Performance + observability

## C-Swift6-Migration — Migrate to Swift 6 strict concurrency mode

**Status**: shipped. `Package.swift` is at `swiftLanguageModes: [.v6]`;
the full test suite (822 tests) passes clean under strict concurrency.
A partial cleanup landed earlier in commit `abaa918` (DocumentProfiler
/ TwoUpDetector / SidecarBridge — the easy three); the rest of the
migration is below.

### What landed

- **`RegionAwareReflow` 8 statics → `Diagnostics` struct** flowing
  through the `Result` return value. `reflow()` declares `var
  diagnostics = Diagnostics()`; `reflowPage` takes it `inout`.
  `PDFToEPUBPipeline.writeDebugLog` now reads
  `reflowDiagnostics.attributions` (etc.) instead of the deleted
  `RegionAwareReflow.lastAttributions`. Deleted unused
  `lastTypographicPromotionsPerPage`. Test that read the static
  (`RegionAwareReflowCrossPageTests`) updated to capture the
  `Result` and read `result.diagnostics.crossPageDecisionsPerPage`.
- **`DOCXWriter` constants → computed properties**. `static let
  bodyFont: NSFont` and `static let newline: NSAttributedString`
  became computed `static var` (NSFont/NSAttributedString aren't
  Sendable; the values are conceptually immutable so trivial cost).
- **`LoadedPDF: @unchecked Sendable`** with a defending doc-comment.
  Invariant: PDFKit access only happens on the pipeline actor's
  executor; all stored properties are `let`; the actor's serializing
  executor prevents simultaneous `PDFDocument` calls even from
  async-let child tasks. Documented in the type so future changes
  don't silently break it.
- **`PDFToEPUBPipeline` sending closures**. `embeddedExtractor` and
  `qualityScorer` marked `private nonisolated let`;
  `runPageOCRPage` and `preparePageForBatch` marked `nonisolated`.
  TaskGroup `addTask` calls now go through a captured method
  reference (`let perform = self.runPageOCRPage`) and a snapshot
  `let pdfRef = pdf` so the `@Sendable` closure body never
  references actor-isolated state. `EmbeddedTextExtractor`,
  `EmbeddedTextQualityScorer`, and `FigureExtractor` gained
  `Sendable` conformance.
- **`QueueViewModel` 2 warnings → errors → fixes**.
  `LanguageOption: Identifiable, Hashable, Sendable`;
  `nonisolated static let supportedLanguages`; capture list
  `[store, runner]` (was `[store, weak runner]`); `runner.start()`
  in the closure body.
- **`HumanistTheme.storageKey`** marked `nonisolated static let`
  so the free `HumanistTheme.current` helper can read it from any
  context without the @MainActor singleton's isolation leaking.
- **`EditorCommandRouter` Task wrapper** removed from the
  `didResignKeyNotification` registration. Init runs on @MainActor,
  so the redundant `Task { @MainActor in }` wrapper was tripping
  Swift 6's Sendable check on `addObserver`'s NSObjectProtocol
  return type. Direct call instead.
- **`EditorViewModel.pdfPageObserver`** marked
  `private nonisolated(unsafe) var`. The token is opaque
  (`NSObjectProtocol`), only accessed in `deinit`, and there's no
  reachable race — the alternative refactors (boxing the token in
  an actor, or moving teardown out of deinit) carry more risk than
  the audited unsafe annotation.

### What didn't pan out as planned

- **Estimate was 14 sites + 2 warnings; actual was ~20**. Cascade
  effects: making one type Sendable surfaced Sendable requirements
  in its consumers (`EmbeddedTextExtractor` /
  `EmbeddedTextQualityScorer` / `FigureExtractor`), and making
  pipeline methods `nonisolated` surfaced isolation issues in stored
  properties they touched. Total time ~4 hours, faster than the
  6-hour estimate because the patterns repeated.
- **PDFKit-on-one-executor invariant verified**. Reading the call
  graph confirmed every `PDFDocument` access is reachable only from
  the pipeline actor's methods or methods explicitly marked
  `nonisolated` and called from the pipeline's executor. The
  `@unchecked Sendable` defense holds.
- **`nonisolated(unsafe)` used exactly once**, for the
  pdfPageObserver case described above. Every other site refactored
  to a true Sendable-clean pattern.

### Why bother

- **Forward compatibility**: every new Swift release tightens
  concurrency checking. Staying on Swift 5 mode means each new toolchain
  surfaces fresh warnings without the codebase improving.
- **Catches real races**: the pre-existing `'runner' captured in
  concurrently-executing code` warning in `QueueViewModel.swift:263`
  is exactly the kind of bug Swift 6 is meant to find. We've been
  sitting on it.
- **Compiler help is free quality**: every issue Swift catches at
  compile time is one fewer Heisenbug to chase at runtime.

### Goal

Build and test cleanly with `swiftLanguageModes: [.v6]`. No
`@unchecked Sendable` escape hatches except where defended by a
specific runtime invariant (e.g. `LoadedPDF` access patterns).

### Scope: 14 error sites + 2 latent warnings

**Pipeline / RegionAwareReflow (8 sites)** — debug introspection
statics: `lastAttributions`, `lastFootnotesPerPage`,
`lastReclassificationsPerPage`, `lastHFReclassificationsPerPage`,
`lastHeadingPromotionsPerPage`, `lastRegionSplitsPerPage`,
`lastCrossPageDecisionsPerPage`, `lastTypographicPromotionsPerPage`.
Same pattern as the already-fixed `TwoUpDetector.lastDiagnostics`:
each is read by the debug-log writer in `PDFToEPUBPipeline`. Refactor
each to flow through the reflow output struct rather than parking in
a global. Probably ~3 hours; the per-static refactor is mechanical
but multiplied by 8 + per-consumer call site updates.

**Pipeline / DOCXWriter (2 sites)** — `bodyFont: NSFont` and
`newline: NSAttributedString` static lets. Conceptually immutable but
NSFont/NSAttributedString aren't `Sendable`. Two clean options:

  - Make them computed properties (~5 ns per access; trivial).
  - Wrap in a `@unchecked Sendable` box that asserts immutability.

Computed property is the cleaner fix. ~10 minutes.

**Pipeline / PDFToEPUBPipeline (2+2 sites)** — async-let captures of
`pdfRef` (the `LoadedPDF` snapshot from the recent
P-Vision-Concurrency change) and progress-callback closures with
`sending` parameters.

The `pdfRef` issue is the deeper one. `LoadedPDF` is intentionally
non-`Sendable` because PDFKit's `PDFDocument` isn't documented as
thread-safe. Two paths:

  - Mark `LoadedPDF: @unchecked Sendable`, defended by an invariant:
    "PDFKit access only ever happens on the pipeline actor's
    executor, so even when async-let creates concurrent child tasks,
    the actor's serializing executor prevents simultaneous PDFKit
    calls." Document the invariant in code so future changes don't
    silently break it. Cleanest if the invariant holds.
  - Remove the concurrency entirely and fall back to serial Vision +
    Surya per-page (loses the ~30% per-page speedup from
    P-Vision-Concurrency).

Path 1 is right. ~1 hour including invariant write-up. The progress-
callback `sending` issues should fall out from the same `@Sendable`
+ explicit-capture-list passes.

**Humanist / QueueViewModel (2 latent warnings → errors)**:
  - `runner` captured in concurrently-executing code (line 263).
  - `supportedLanguages` main-actor-isolated static accessed from
    nonisolated context (line 242).

Both real problems. The first is a closure capturing a `var runner`
across a Task; either rebind to `let` or restructure. The second is
a `@MainActor`-implicit static that's read from a nonisolated method;
mark the access path either `@MainActor` or move the data to an
unisolated holder.

### Effort

~6 hours total broken down:
- ~3 hours: RegionAwareReflow's 8 statics → return-value plumbing.
- ~1 hour: DOCXWriter constants → computed properties.
- ~1 hour: LoadedPDF + progress-callback Sending fixes; verify the
  PDFKit-on-one-executor invariant by reading the call graph.
- ~30 min: QueueViewModel rebinds.
- ~30 min: flip Package.swift to `.v6`, run `swift test`, fix any
  test-target stragglers.

### Risks

- **PDFKit-on-one-executor invariant could be wrong**. If
  `analyzeLayoutWithRetry`'s retry path actually hops executors, the
  `@unchecked Sendable` defense fails. Verify before committing.
- **Test-target Swift 6 issues**. `swiftLanguageModes` is per-package,
  so test targets get the same strict checks. Likely surfaces a few
  more issues in test fixtures (e.g. captured-state in async test
  setup).

### Outcome

Shipped, ~4 hours actual vs ~6 hours estimated. Compiler help is now
free quality across the codebase: every future Swift toolchain that
tightens concurrency checking will surface issues at build time
rather than waiting for a Heisenbug to trigger at runtime. The
QueueViewModel `runner` capture warning that prompted the migration
is now a hard compile-time constraint that can't regress.

---

## R-Chat-Embeddings — Hybrid BM25 + embedding retrieval for chat-with-book

**Status**: shipped over commits `452daeb` (foundation), `a421161`
(Ollama), and `1d4cb71` (Voyage + Gemini). Chat retrieval is now
per-paragraph hybrid: BM25 chapters projected onto their paragraphs
+ embedding cosine, fused via RRF (k=60). Default embedding backend
is on-device Apple NLEmbedding (free, no setup); Ollama / Voyage /
Gemini are wired alternatives. Per-book sidecar caches vectors
under `~/Library/Application Support/Humanist/Embeddings/<sha256>.json`
so the second open is instant; per-paragraph hashing means a save
re-embeds only the paragraphs that changed. 13 new tests cover the
math, paragraph extraction, sidecar round-trip, and RRF fusion.

### What landed

- **Foundation pass** (`452daeb`): `EmbeddingBackend` protocol +
  `NLSentenceEmbeddingBackend`; `BookEmbeddingIndex` with cosine
  search; `EmbeddingsSidecarStore`; `HybridRetriever` with RRF;
  per-paragraph context rendering; Settings → AI → Chat Retrieval
  section with index-size readout + Clear button.
- **Ollama backend** (`a421161`): `OllamaClient.embed(model:texts:)`
  + `OllamaEmbeddingBackend` with daemon-probe-on-init for the
  dimension. `nomic-embed-text` is the recommended model.
- **Voyage + Gemini backends** (`1d4cb71`): generalized
  `KeychainAPIKeyStore` so adding a third + fourth provider key was
  a 30-line shim each (`VoyageAPIKeyStore`, `GeminiAPIKeyStore`).
  HTTP backends both probe for dimension before returning. Gemini
  exposes `outputDimensionality` (Matryoshka 768 / 1536 / full)
  for storage / quality tradeoffs.

### Storage choice that diverged from the plan

The plan called for the embedding cache to live inside the EPUB at
`META-INF/com.humanist.embeddings.json`. Shipped as a sidecar
under Application Support instead, matching the existing
`ChatTranscriptStore` pattern: derived state shouldn't couple to
the EPUB save flow (would force a full re-zip on every paragraph
edit) or pollute a spec-faithful EPUB with a 2 MB binary blob.
Tradeoff: moving the .epub file orphans its sidecar; rebuild on
next open is ~1 minute with NLEmbedding, acceptable.

### Outcome

Shipped, ~1 day actual vs ~3-4 days estimated — the keychain
generalization shaved per-provider cost and the protocol-driven
backend split made each new provider a ~60-line addition.

### Why bother

BM25 is a keyword overlap score. It works well when the user's
question shares vocabulary with the answer:
*"Where does Foucault discuss heterotopia?"* finds the chapter that
literally says "heterotopia." It works poorly when the question is
conceptual or uses different words than the source:
*"What does the author say about spaces of otherness?"* gets nothing
useful because none of the keywords overlap.

Embeddings invert that — they find *conceptually similar* passages
even when the wording differs. The right answer for academic chat
isn't *replacing* BM25 with embeddings (you'd lose the precision on
direct-mention queries); it's combining the two.

### Goal

Hybrid retrieval that runs both BM25 and a vector cosine search,
combines them via reciprocal rank fusion (RRF), and returns the
top-k merged results. Granularity drops from per-chapter to
per-paragraph so the context window doesn't have to swallow whole
chapters when only a few paragraphs are relevant.

### Architecture

```
Sources/Humanist/Editor/Chat/
├── BookKeywordIndex.swift       (existing — BM25 over chapters)
├── BookEmbeddingIndex.swift     NEW — per-paragraph embeddings + cosine
├── HybridRetriever.swift        NEW — BM25 + embedding RRF fusion
└── BookChatViewModel.swift      route through HybridRetriever
```

**`BookEmbeddingIndex`**: holds `[(chapterIdx, paragraphIdx, vector)]`
plus the parallel paragraph text array. Cosine similarity against the
query vector returns top-k by similarity. Pure Swift; for the
expected size (~1k–3k paragraphs per book), a brute-force scan beats
any tree structure on this CPU.

**`HybridRetriever`**: takes a query string, returns
`[ScoredParagraph]`. Internally:

1. Embed the query.
2. BM25 over chapters → list of (chapterIdx, score).
3. Cosine over paragraph vectors → list of (chapter+paragraph, score).
4. RRF fusion: `score = sum over rankers of 1/(k + rank)` with k=60.
5. Top-N paragraphs returned; chapter-level BM25 hits convert to
   "all paragraphs from that chapter, ranked by their cosine within
   the chapter."

### Embedding backend

Four tiers, picked at Settings level (similar to chat backend):

- **Local — Apple `NLEmbedding`** (default). Built into the
  `NaturalLanguage` framework, on-device, free, works for the major
  Western European languages + Chinese / Japanese / Russian.
  Quality: moderate but adequate for this use case. Latency: ~10 ms
  per paragraph; embedding a 300-page book is a one-shot ~1-minute
  cost.
- **Local — Ollama** (e.g. `nomic-embed-text`). Better quality, more
  memory, ~50-200 ms per paragraph. Requires the Ollama daemon
  (which the local-chat path already uses).
- **Cloud — Voyage AI** (`voyage-3` or `voyage-3-lite`). Anthropic's
  recommended embedding provider. ~$0.02 / 1M tokens, ~$0.005 per
  book. Strong on technical/academic English.
- **Cloud — Gemini Embedding 2** (`gemini-embedding-002`,
  released March 2026). Currently #1 on the MTEB multilingual
  leaderboard — beats the runner-up by ~6 points. 100+ languages
  including ancient/classical scripts; 8K-token input window;
  Matryoshka representation lets us truncate the 3072-dim output
  to a smaller dimension for cheaper storage with minimal quality
  loss. The right default for a corpus heavy on classical Greek,
  Latin, and other multilingual academic content. Requires a
  Google AI Studio API key.

The chat backend choice (Cloud Haiku/Sonnet, Local Ollama) and the
embedding backend choice are independent — a user might run Cloud
Sonnet for chat answers but use free local NLEmbedding for
retrieval, or vice versa.

For Humanist's actual corpus (academic books with classical-script
passages), **Gemini Embedding 2 is probably the right default for
users who already use Cloud features** — the multilingual lead over
Voyage and the open-source field is large and the cost is trivial
(~$0.005/book). NLEmbedding stays as the offline default for
Private-mode users.

### Per-book persistence

Embedding a 300-page book takes ~1-2 minutes (NLEmbedding) or
~$0.005 (Voyage). Doing it on every editor open is wasteful. Cache
the vectors in a per-EPUB sidecar:

```
META-INF/com.humanist.embeddings.json
```

Schema (JSON, gzipped if size becomes a concern):

```jsonc
{
  "schemaVersion": 1,
  "backend": "nlembedding|ollama:nomic-embed-text|voyage-3",
  "dimension": 384,
  "spineFingerprint": "sha256:...",   // invalidate if spine changes
  "paragraphs": [
    {
      "chapterIdx": 0,
      "paragraphIdx": 12,
      "textHash": "sha256:...",
      "vector": [0.123, -0.456, ...]
    },
    ...
  ]
}
```

Sidecar invalidation:

- Whole-book invalidate when the backend or dimension changes.
- Per-paragraph invalidate when its `textHash` differs from the
  current text — re-embed only those paragraphs after a save.

Storage size: ~1500 paragraphs × 384 floats × 4 bytes = ~2.3 MB per
book uncompressed, ~1 MB gzipped. Trivial on disk.

### Re-embedding triggers

- **First open after install**: build the index from scratch. Pane
  shows a "Indexing for chat-with-book…" hint while it runs.
- **After save**: re-embed paragraphs whose `textHash` changed.
  Hooks into the same `wysiwygReloadToken` → save cycle as the
  WYSIWYG-vs-Source sync.
- **Backend switch**: full rebuild (new dimension + different vector
  space).

### Settings

New "Chat retrieval" subsection under Settings → AI → Book Chat:

- **Retrieval style**: BM25 only · Embeddings only · Hybrid
  (default)
- **Embedding backend**: Apple NLEmbedding (default) · Ollama
  (model picker) · Voyage (key entry)
- **Index size**: shows MB used by the embeddings sidecar across all
  cataloged EPUBs. Button: "Clear all indexes" (wipes the sidecars;
  rebuild on next open).

### Cost / latency budget

| Backend | Embed once | Embed re-edit | Per-query |
|---|---|---|---|
| NLEmbedding | ~1-2 min/book | ~50 ms/paragraph | ~10 ms |
| Ollama (`nomic-embed-text`) | ~5-10 min/book | ~200 ms/paragraph | ~50 ms |
| Voyage (`voyage-3`) | ~$0.005/book | ~$0.0001/paragraph | ~100 ms |
| Gemini Embedding 2 | ~$0.01/book | ~$0.0002/paragraph | ~150 ms |

Per-query is dominated by retrieval, not embedding — query embedding
is a single call.

### Risks

- **Mediocre quality on classical/multilingual text**. NLEmbedding
  was trained on contemporary corpora; polytonic Greek and classical
  Latin may embed poorly. The Voyage path (or a domain-specific
  Ollama model) hedges this.
- **Sidecar bloat for large libraries**. 100 books × 1 MB = 100 MB
  inside EPUBs that the user might not realize they're carrying.
  Mitigation: gzip-encode the sidecar; offer a "Clear all indexes"
  button.
- **Drift between BM25 and embedding rankers**. RRF handles this
  gracefully but the mixing constants (k=60) might need tuning per
  corpus. Start with the standard value; expose as a hidden
  preference if real-world testing demands it.

### Effort

~3-4 days end-to-end:
- ~1 day: `BookEmbeddingIndex` with NLEmbedding backend (build,
  cache, query) + sidecar write/read.
- ~0.5 day: `HybridRetriever` + RRF fusion + per-paragraph
  granularity refactor through `BookChatViewModel`.
- ~0.5 day: Ollama embedding backend (mostly the existing
  `OllamaClient` pattern, just `/api/embed`).
- ~0.5 day: Voyage backend (HTTP client, key entry in Settings,
  same shape as the existing AnthropicAPIClient).
- ~0.5 day: Settings UI + clear-indexes action + index-size
  reporting.
- ~0.5 day: integration testing on real books, threshold tuning,
  fixture tests.

### When to ship

Anytime now — the Swift 6 migration shipped, so the embedding
cache crossing the chat ViewModel's isolation gets Sendable-clean
enforcement from the compiler at build time.

### Dependencies

- `NaturalLanguage` framework — already available, no new dependency.
- Ollama — already optional; if the user already set up local chat,
  same daemon and same `OllamaClient` plumbing (just hit `/api/embed`
  instead of `/api/chat`).
- Voyage / Gemini API keys — new optional credentials. Generalize
  `AnthropicAPIKeyStore` into a multi-service `APIKeyStore` (Anthropic,
  Voyage, Google AI Studio) so the Settings → AI pane has one place
  for keys instead of three parallel stores.

---

## R-Chat-Polish — Chat embedding papercuts

**Status**: not started. Small UX gaps in the chat / embedding
surface that aren't blockers but would noticeably improve daily use.
Each item is independently shippable in 30 minutes to 2 hours.

### Backlog

- **Bulk-index command** — Library window action that walks every
  cataloged EPUB and builds (or refreshes) its embedding index. Today
  each book waits until its chat pane opens; on a large library that
  means hand-opening every book once. Background queue with progress;
  read the per-book sidecar to skip ones that are already complete +
  current. ~2 hours.
- **Per-book "Rebuild index" button** — surfaced from the chat pane
  header, the editor's File menu, or the Library row context menu.
  Wipes that one book's sidecar and rebuilds. The current alternative
  is "Settings → Clear all", which is heavier than usually wanted.
  ~30 minutes.
- **Backend-fallback visibility** — `BookChatViewModel.resolveEmbedding
  Backend` already returns a `fallbackNote` (e.g. "Voyage embedding
  unavailable: missing API key. Using Apple NLEmbedding instead.")
  but the chat-pane status strip doesn't surface it. Surface as an
  inline notice next to the indexing strip when present. Catches
  silent fallbacks the user otherwise wouldn't notice. ~30 minutes.
- **Backend-swap cascade** — when the Settings backend changes, all
  open editor windows continue to use the old vectors until they
  reload. Either invalidate `embeddingIndex` proactively across all
  registered chat view-models when the choice changes, or surface a
  "Backend changed; reopen editor windows to apply" notice. ~1 hour.
- **Paragraph-level citation jumps** — `HybridRetriever.Hit` carries
  `paragraphIdx` but the citation chips navigate to the chapter root.
  Chat would feel more precise if a citation scrolled the editor to
  the cited paragraph (`<p id="hu-p-N-M">`) rather than the chapter
  top. ~1 hour. Requires a small editor selection API.
- **Retrieval debug surface** — `bm25Rank` / `embeddingRank` / score
  fields on each hit aren't exposed anywhere. A "Show retrieval
  detail" toggle on the chat pane that prints the scored paragraph
  list under each user message would help when retrieval feels
  wrong. ~1 hour.
- **Tunable knobs in Settings** — `RRF k=60`, `topK=12 paragraphs`,
  `maxParagraphChars=4000` are reasonable defaults but aren't
  surfaced. Hidden / advanced section in Settings → AI for power
  users. ~1 hour.
- **Window-switcher menu commands** — `Window > Show Converter`
  / `Show Library` / `Show Editor` shortcuts (e.g. `⌘1` / `⌘2` /
  `⌘3`). The macOS Window menu lists every open window, but a
  fast keyboard switch between the three "primary" surfaces
  (converter / library / most-recent editor) is the usual
  navigation move and deserves a top-level chord. `Show Library`
  + `Show Queue` already exist in the menu; this rounds them
  out and adds the converter + most-recent-editor entries. ~30
  minutes, but synergizes with the library-chat surface below
  since that becomes a frequent navigation target.

### When to ship

Anytime; pick whichever items are biting hardest. None of them
require new infrastructure.

---

## R-Library-Chat — First-class library window with embedded chat

**Status**: not started. Today the only way to ask a cross-corpus
question is to open a book and flip the chat pane's scope picker
to "Whole library." The library *itself* is just a browser — list
of EPUBs with thumbnails + metadata + bulk find/replace. Promoting
the library window to a primary surface (alongside the converter
and editor) with its own embedded chat pane removes the awkward
"open a book to query the library" step.

### Why bother

The multi-book scope landed in `R-Chat-Graph-Lite` works, but it's
discoverable only after opening a book. A corpus-level question
("which books discuss X across my library?") reads as a corpus-level
operation; it shouldn't require picking an arbitrary anchor book to
get to the chat surface. A first-class library window with chat puts
the surface where the user expects it and makes multi-book chat the
default UX rather than a tucked-away mode.

### Scope

- **`LibraryChatViewModel`** — a thinner sibling of
  `BookChatViewModel` that only knows how to do library-scope
  retrieval. No current-book reference, no `bookDidReload`, no
  per-book embedding index. Builds the `LibraryEmbeddingIndex` on
  init; rebuilds when the backend changes; sends through the
  existing library cloud / Ollama paths with the
  `[book:N chapter:M]` citation format. Either factor common
  helpers out of `BookChatViewModel` into a shared file or have
  `BookChatViewModel`'s library send path stay the canonical
  implementation and let `LibraryChatViewModel` delegate.

- **Library window layout** — the existing browser (cover thumbnail
  list + filter / search) stays as the primary content, with a
  chat pane attached on the right (or as a sheet / drawer for
  smaller windows). Pane is collapsible — power users who want
  the full list view can hide chat. Scope picker is implicit
  (always library) so the chat pane shows just the indexing /
  status row, not a scope selector.

- **Citation behavior** — same as today's library citations: a tap
  routes through `OpenRouter.open` to surface the cited book in
  its own editor window. The library window keeps its place as
  the corpus-level command center.

- **Window-switcher commands** — see the entry in `R-Chat-Polish`.
  Belongs here because it makes the library window a first-class
  navigation target alongside the converter and the most-recent
  editor.

### What this doesn't change

- `BookChatViewModel`'s scope picker stays — a user reading a
  specific book may still want library-scope retrieval anchored
  in that editor window without window-switching. The two
  surfaces are complementary.
- The library catalog persistence (`LibraryStore`, `library.json`)
  is unchanged; the chat pane consumes the same data the browser
  does.

### Effort

~1-1.5 days end-to-end:
- ~0.5 day: `LibraryChatViewModel` (factor or delegate).
- ~0.5 day: library window layout — split view with collapsible
  chat pane, accessibility, dark-mode sanity, theme integration.
- ~0.5 day: window-switcher commands + Show Editor / Show
  Converter / Show Library / Show Queue rounded out.

### When to ship

After the entity / four-way-fusion work in R-Chat-Graph-Lite
finishes, or interleaved if the entity work hits a subtle
problem. The library-chat surface doesn't depend on entities;
it's an orthogonal UX promotion.

---

## R-Chat-Graph-Lite — Hierarchical + entity graphs for chat retrieval

**Status**: in progress. Hierarchy primitive + multi-book chat scope
shipped (commits `189fe37` + `ae65e95`); BookEntityIndex /
LibraryEntityIndex / four-way RRF fusion / Settings toggles still
pending.

### What landed so far

- **BookHierarchyIndex** (`189fe37`): nav.xhtml → chapter/section
  tree, with token-overlap title matching and `chapter N` /
  `section N` structural-pattern detection. Cached in the per-book
  sidecar (schema bumped to v2). System prompt gains a compact
  table of contents preamble so the model can interpret structural
  references without consuming retrieval budget.
- **Multi-book chat scope** (`ae65e95`): `LibraryEmbeddingIndex`
  federates per-book sidecars whose backend identifier + dimension
  match the resolved backend; brute-force cosine across all sources.
  Scope picker (segmented) at the top of the chat pane flips
  between "Current book" (default, today's behavior) and "Whole
  library". Library citations carry book + chapter; clicking opens
  the cited book in a new editor window via `OpenRouter.open`.
  EmbeddingsSidecar.Entry gained an optional `text` field so
  library-scope queries don't have to unzip the cited EPUB on
  every hit (with a fallback for older sidecars without text).
- **NER entities + four-way RRF fusion** (`d28a9d8`):
  `BookEntityIndex` runs NLTagger `.nameType` over every paragraph
  and aggregates personal / place / org names into a `canonical →
  [anchor]` table. `LibraryEntityIndex` federates across per-book
  sidecars; supports cross-corpus entity queries and set queries.
  `HybridRetriever` extended to a four-way RRF: BM25 chapter
  projection + embedding cosine + hierarchy-set + entity-set;
  hierarchy / entity rankers contribute a fixed rank-1 boost
  (they tag a set as relevant rather than ranking within).
  `LibraryEmbeddingIndex.search` also folds library-wide entity
  matches into a two-way RRF on the library scope. Settings
  toggles for structural / entity retrieval (default on) so users
  can turn off the boosts at retrieval time without invalidating
  sidecars.
- **Variable-granularity render + alias dictionary**: when 4+
  paragraph hits cluster in one chapter, the render path
  surfaces the whole chapter (capped at 30 KB) instead of
  individual bullets — the model gets surrounding context that's
  often what cluster-shaped queries actually want. Other
  chapters keep paragraph-level rendering. The alias dictionary
  is a per-library text editor (Settings → AI → Chat Retrieval →
  Alias dictionary) where users add concepts NLTagger missed —
  one term per line. At query time, alias matches scan paragraph
  texts and contribute the same RRF boost as NER entities. Same
  Settings toggle gates both NER and alias retrieval.

### Still pending

- Section-level granularity — chapter-level expansion shipped;
  section-level expansion (sub-chapter scope when paragraphs
  cluster in one nested section) is a finer cut that requires
  mapping paragraphs to section anchors. R-Hierarchy already
  emits the anchors; consuming them precisely is a follow-up
  worth doing only if chapter-level proves too coarse.

### Why bother

Hybrid BM25 + embedding retrieval covers most chat queries well, but
two query shapes fall through the gaps:

- **Structural** — "summarize chapter 3," "what's the argument of
  the section on heterotopia?" Embeddings return ranked paragraphs;
  what the user actually wants is a discussion at the section or
  chapter scope. The hierarchy is already implicit in the EPUB
  (`nav.xhtml`, `hu-page-N`, `hu-p-N-M` anchors); making it
  explicit as a retrieval primitive is nearly free.
- **Exhaustive** — "every mention of Aristotle across all my books,"
  "which books discuss both Foucault and Bourdieu?" Embeddings give
  ranked top-K, not exhaustive enumeration. Set operations over an
  entity index are the right tool.

This isn't GraphRAG — no LLM-extracted entity-relation triples, no
community detection, no multi-level summarization. Two narrow,
high-leverage primitives that compose with the hybrid retriever.

### Scope: two primitives

**Primitive 1 — Hierarchical structure graph**

Per-book tree: `book → chapter → section → paragraph`. Nodes carry
their EPUB anchor (`hu-page-N`, `hu-p-N-M`) so click-to-navigate
works the same way the existing chat citations do.

Built from `nav.xhtml` (which Humanist already produces, with
nested `<ol>` levels for sections within chapters via the existing
`R-Hierarchy` work). No additional analysis needed — the tree
exists; we just expose it as a retrieval target.

Used for variable-granularity expansion: when the embedding stage
returns N paragraphs that all sit within one section, the
retriever offers the section as the answer scope instead of just
the matched paragraphs. Also enables direct structural queries:
"give me chapter 3" walks that subtree.

**Primitive 2 — Light entity index**

Per-book sidecar: `entity name → [paragraph anchors]`. Entities
extracted via Apple's `NLTagger` with `.nameType` scheme — gives
PERSON / PLACE / ORG / DATE on contemporary text out of the box,
no API key, on-device. Quality on classical Greek and Latin will
be weaker; document this as a known limitation.

Library-level federation: union the per-book entity tables, deduped
by canonical form. Query path:

1. Detect entity mentions in the query (same `NLTagger` pass).
2. For each detected entity, look up the federated entity index.
3. Retrieve all paragraph anchors mentioning that entity.
4. Pass to the model as additional context alongside the BM25 +
   embedding hits.

Set queries fall out for free: "books mentioning both X and Y" is
just a set intersection on the entity index.

### Architecture

```
Sources/Humanist/Editor/Chat/
├── BookHierarchyIndex.swift     NEW — tree built from nav.xhtml
├── BookEntityIndex.swift        NEW — NLTagger-driven mentions table
├── HybridRetriever.swift        EDIT — fold hierarchy + entity hits
│                                  into the RRF fusion alongside BM25
│                                  + embeddings
└── (LibraryEmbeddingIndex)      cross-book federation pattern from
                                   R-Chat-Embeddings reused for entity
                                   index federation
```

`HybridRetriever` becomes a four-way fusion (BM25 + embeddings +
hierarchy expansion + entity matches) via reciprocal rank fusion.
Each retriever returns ranked candidates with the same paragraph-
anchor identity; RRF combines them with k=60.

### Per-book persistence

R-Chat-Embeddings stores its sidecar at
`~/Library/Application Support/Humanist/Embeddings/<sha256>.json`,
*not* inside the EPUB. Same path here. Extend the existing payload
with two new top-level sections rather than spawning sibling files:

```jsonc
{
  "schemaVersion": 2,                 // bumped from 1
  "backendIdentifier": "...",
  "dimension": 384,
  "paragraphs": [...],                // unchanged from R-Chat-Embeddings
  "hierarchy": {                      // NEW
    "nodes": [
      { "id": "ch-0", "kind": "chapter", "anchor": "hu-page-1",
        "title": "On Heterotopias",
        "children": ["sec-0-0", "sec-0-1"] },
      ...
    ]
  },
  "entities": {                       // NEW
    "Foucault": ["hu-p-2-12", "hu-p-3-7", ...],
    "heterotopia": ["hu-p-3-9", ...],
    ...
  }
}
```

Schema version bump triggers a full rebuild on first open after the
upgrade — the existing `EmbeddingsSidecarStore.read` already drops
mismatched sidecars, so a v1 → v2 transition just re-runs the
embedding pass plus the new hierarchy / entity passes.

Per-paragraph re-edits trigger entity re-extraction for those
paragraphs; hierarchy is stable across paragraph-level edits (it
changes only on Split / Merge / Move Chapter, which already post a
structural-dirty signal via the existing chapter-operations
plumbing).

### Library-level federation

R-Chat-Embeddings shipped per-book chat only — no cross-library
retrieval. This task adds three federated indexes:

- `LibraryEmbeddingIndex` — aggregates per-book paragraph vectors
  for cross-library cosine search. Built on demand from the existing
  per-book sidecars. Citations carry book + chapter (not just
  chapter) so a hit in book X navigates the user to the right place
  in the right book.
- `LibraryHierarchyIndex` — flat list of all chapters/sections in
  the library, indexed by `(bookID, anchor)`. ~50 KB per book.
  Lazy-loaded; doesn't need to all sit in RAM.
- `LibraryEntityIndex` — federated entity → `[(bookID, anchor)]`
  table. Held in memory at chat time; ~1-5 MB total for a 100-book
  library depending on entity richness.

### Multi-book chat scope

R-Chat-Embeddings ships per-book chat: each chat session sees one
EPUB. Federation enables a "library" scope; we don't want it
silently to take over the existing per-book sessions, so a scope
picker is needed.

- **Current book** (default for newly-opened chat panes) — today's
  behavior. Retrieval scoped to one EPUB; citations are chapter-
  level chips that navigate within the editor window.
- **Whole library** — every book that has a sidecar participates.
  Citations carry book + chapter. Clicking a citation opens a new
  editor window on the cited book at the cited chapter.

Surface as a small picker at the top of the chat pane (above the
transcript) so users can flip per-question without leaving the
chat. The choice is per-window, not global — a user can have one
book's editor in "Current book" mode and another window in
"Whole library" mode.

Only books with a complete sidecar participate in library mode; a
status row ("87 of 124 books indexed") lives next to the picker
and links to the bulk-index command from `R-Chat-Polish`.

### Settings

Single subsection added to Settings → AI → Book Chat:

- **Use structural retrieval**: bool, default on. Adds hierarchy
  expansion to the fusion.
- **Use entity retrieval**: bool, default on. Adds entity-index
  matches to the fusion.

Both are local / free / fast — no separate backend choice. NLTagger
runs on-device.

### What's deliberately out of scope

- **Citation graphs** ("Book A cites Book B"). Bibliography parsing
  is a real ML project on its own; demand hasn't surfaced.
- **GraphRAG-full** (LLM-extracted entity-relation triples + multi-
  level community summaries). Massive engineering investment for
  marginal gain on a single-user tool. Document the design pointer
  but don't implement.
- **LLM-extracted entities**. Apple's NLTagger is good enough on
  contemporary English; the upgrade path is documented but not
  default. If real-world testing shows NER misses are degrading
  query quality, revisit with a Haiku-extraction backend then.

### Risks

- **NLTagger quality on classical text**. Polytonic Greek / Latin
  entities won't be detected reliably. Documented limitation;
  partial mitigation via an "alias dictionary" (per-book or
  per-library) the user can edit to add canonical names that
  NER missed.
- **Entity disambiguation across books**. "Aristotle" in two books
  is presumably the same entity, but a 20-volume corpus might
  contain multiple "John Smiths." Default behavior: dedup by
  surface form (treat all "Aristotle" mentions as one node). Good
  enough until a real ambiguity surfaces; can later add
  context-aware disambiguation.
- **Sidecar schema drift**. Adding hierarchy + entities to the
  embeddings sidecar means a v1-schema sidecar is incomplete.
  Detect via `schemaVersion`, rebuild from scratch on first open
  after the upgrade. Annoying for users with many indexed books
  but bounded (NLTagger is fast; full library re-index is minutes,
  not hours).

### Effort

~4-5 days end-to-end:
- ~1 day: `BookHierarchyIndex` (tree from nav.xhtml + sidecar
  read/write + schema bump migration).
- ~1 day: `BookEntityIndex` via NLTagger + sidecar plumbing +
  per-paragraph re-extraction on edit.
- ~0.5 day: `HybridRetriever` extended to four-way RRF fusion.
- ~1 day: `LibraryEmbeddingIndex` + `LibraryHierarchyIndex` +
  `LibraryEntityIndex` federation; multi-book chat scope picker;
  book-aware citation chips that open a new editor window on click.
- ~0.5 day: Settings toggles + alias-dictionary UI for missed
  entities.
- ~0.5 day: integration testing on real books (mixed contemporary
  + classical content), threshold tuning.

### When to ship

Anytime — `R-Chat-Embeddings` shipped, and the per-book sidecar
infrastructure it established is what this builds on. The four-way
RRF fusion + library federation is the natural next pass.

### Dependencies

- `R-Chat-Embeddings` for the per-book sidecar pattern.
- `NaturalLanguage.NLTagger` — already available; no new
  dependency.
- The existing `R-Hierarchy` work (nested `<ol>` in nav.xhtml)
  already provides the section-level hierarchy this primitive
  consumes.

---

## E-Vision-Modes — Manuscript mode (Claude) + Early Print mode (Gemini)

**Status**: not started. Two new per-conversion modes that route
pages through a flagship vision model with a content-tuned prompt
instead of the default printed-book pipeline. Different models for
different content types because their training priors point in
different directions.

### Why two modes (not one)

Modern VLMs all clear "good enough" on character recognition; what
differentiates them on hard sources is **transcription posture**.

- **Manuscript content** (medieval / early-modern handwriting,
  scribal abbreviations, marginalia, faded ink) wants
  **diplomatic transcription** — preserve abbreviations, mark
  uncertainty with brackets, don't "helpfully" normalize. Claude
  Opus 4.7 has been trained for this kind of fidelity-over-fluency
  posture. It tends to flag illegibility (`⟨illegible⟩`) rather
  than guess, and preserves period-specific orthography.
- **Early printed content** (incunabula, Gothic blackletter,
  19th-century cursive newsprint, dense ligature-heavy fonts)
  wants **strong typeface priors** + fluent normalization. Gemini
  3.1 Pro has trained on a lot of historical-corpus material via
  Google Books / the Library Project; its priors for older
  typefaces are deeper than competitors'. The "fluency over
  fidelity" trade is right for printed content where the source
  *was* meant to be normalized.

Same model in both roles would be the wrong answer for one of them.
Two modes gives the user the right posture for each content type
without making them tune prompts manually.

### Validation spike (do first)

Empirical recommendation beats my prior. Before committing to the
full implementation, run a one-day spike:

1. **CLI command** `humanist-cli vision-spike <image>
   [--mode manuscript|early-print] [--model claude|gemini]`.
   Takes one page image, runs through one or both
   model+prompt combos, prints transcriptions side-by-side.
2. **Hand-correct 2–3 pages** as ground truth from the user's
   actual target corpus.
3. **Compute CER** for each combo. Pick the winner per mode.
4. **Document the prompt template** that produced the winner —
   the prompt is half the work.

If the spike contradicts the prior (e.g. Gemini turns out better
on manuscripts because the user's corpus is mostly modern cursive
where Google's training helps), swap the model assignment and
ship. If the spike confirms, implement as planned.

### Architecture

Both modes are page-level OCR engines that bypass the `RegionCascade`
+ Vision/Tesseract path. Each engine:

```
Sources/Pipeline/
├── ClaudePageOCREngine.swift    (existing — Sonnet 4.6 default)
├── ClaudeManuscriptEngine.swift NEW — Claude Opus 4.7 + diplomatic prompt
└── GeminiEarlyPrintEngine.swift NEW — Gemini 3.1 Pro + early-print prompt
```

`ClaudeManuscriptEngine` reuses `AnthropicAPIClient` (different
model + prompt template). `GeminiEarlyPrintEngine` is a new HTTP
client paralleling `GeminiEmbeddingBackend` (key store already
exists; same `?key=<api_key>` auth pattern).

Per-page output is structured XHTML (matches the existing page-OCR
output shape so downstream reflow / packager code is unchanged).
Both engines emit the same `[Block] + [Footnote]` shape; the
difference is in *what they produce*, not how it's consumed.

### Prompt templates (sketch)

**Manuscript prompt** (Claude Opus):

```
You are transcribing a manuscript page. Produce a diplomatic
transcription: preserve scribal abbreviations as written (do not
expand them silently); preserve period-specific orthography (long
s, u/v variations, etc.); mark unreadable spans as ⟨illegible⟩;
mark uncertain readings as ⟨...?⟩; render line breaks as <br/>
when they're meaningful (verse, marginalia); do not normalize
spelling, capitalization, or punctuation. If the page has
marginalia, render them after the main text in a separate block
labeled "Margin:".
```

**Early-print prompt** (Gemini Pro):

```
You are transcribing a page from an early printed book. Produce
a clean, normalized transcription: expand period-specific
ligatures (æ, œ, long s, etc.) into modern equivalents; correct
obvious typesetting artifacts (e.g. damaged single letters that
context resolves); preserve original line breaks within
paragraphs only when they appear to be intentional; flag any
uncertain reading with `<sic>uncertain</sic>` so a human can
verify. The output should read as modern prose; the original
typesetting is captured in the source PDF.
```

Both prompts are tunable in code (no UI surface for prompt
editing in v1; the templates live in their respective engine
files).

### Settings / UI

Per-conversion picker in the launcher window, alongside the
existing High Accuracy / Force OCR toggles. Values:

- **Print** (default) — current pipeline.
- **Manuscript** — routes through `ClaudeManuscriptEngine`.
  Requires Anthropic key + Cloud mode.
- **Early Print** — routes through `GeminiEarlyPrintEngine`.
  Requires Gemini key (stored via the existing `GeminiAPIKeyStore`
  the embedding work added).

Per-conversion not per-app since a user's library mixes content
types. The choice persists per-job in the queue but doesn't bleed
into the global Cloud-feature toggles.

### Cost / latency

Rough estimate (without spike-confirmed numbers):

| Mode | Per-page cost | 200-page book | Latency |
|---|---|---|---|
| Manuscript (Opus 4.7) | ~$0.05 | ~$10 | ~8-15 s/page |
| Early Print (Gemini 3.1 Pro) | ~$0.04 | ~$8 | ~5-10 s/page |
| Print (Sonnet 4.6, current) | ~$0.01 | ~$2 | ~3-5 s/page |

Both new modes are 4-5× the cost of the default print mode but
produce qualitatively different output. Surface in the conversion
summary so users know what they're committing to before clicking
Convert. Per-book cost cap (`AISettings.perBookCallCap`) already
guards against runaway documents.

### Risks

- **Layout failures**: marginalia, multi-column manuscripts, and
  glosses break the simple page-level output shape. v1 emits
  what the model produces; v2 could add layout-aware prompting
  or fall back to Surya layout for spatial reasoning.
- **Damaged pages**: water damage, palimpsests, and very faded
  ink hit the recall floor of any general-purpose VLM. Manual
  correction in the editor is the escape hatch — the
  `correction-trail.json` sidecar already captures edits so
  re-runs preserve them.
- **Specialized scripts that need fine-tuning**: cuneiform,
  epigraphic Greek, cursive Hebrew — these benefit more from
  Transkribus / Kraken with per-script training than from a
  general VLM. Document as a known limitation; recommend
  external tools when it surfaces.
- **Model drift**: prompt templates that work today may need
  re-tuning as model updates ship. Pin the model version in
  Settings → AI so the user controls when an upgrade lands.

### Effort

~2-3 days end-to-end after the spike validates the model picks:

- ~0.5 day: validation spike CLI + ground-truth comparison.
- ~0.5 day: `ClaudeManuscriptEngine` (mostly an
  `AnthropicMessageRequest` factory + the diplomatic prompt
  template + per-mode response parsing).
- ~0.5 day: `GeminiEarlyPrintEngine` (HTTP client + Gemini
  vision request shape — `gemini-3.1-pro` accepts inline base64
  images; key auth is `?key=` query param like the embedding
  client).
- ~0.5 day: launcher UI picker + per-conversion mode plumbing
  through `ConversionOptions`.
- ~0.5 day: integration tests on 5-10 pages of each type;
  prompt iteration based on actual output.

### When to ship

After R-Library-Chat or interleaved with it — the modes are
independent of the chat work and use disjoint code paths. Spike
first, then implement; both modes can land in one PR or split
into two if Manuscript is more pressing.

### Dependencies

- Anthropic API key — already in keychain via
  `AnthropicAPIKeyStore`.
- Gemini API key — already in keychain via `GeminiAPIKeyStore`
  (added for embeddings in R-Chat-Embeddings).
- Existing `ClaudePageOCREngine` plumbing — the new engines
  follow its shape so downstream block / reflow code is
  unchanged.
- `AISettings.cloudFeatures` is the natural place to add per-mode
  toggles (rather than UserDefaults sprawl); follow the
  existing field-with-decodeIfPresent pattern so older
  persisted settings still load.

---

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

**Status**: shipped. Vision OCR and Surya layout now run concurrently
via `async let` in the cascade per-page loop. `pageBounds` hoisted
from post-OCR to pre-concurrent (it's pure image geometry). The
`analyzeLayoutWithRetry` guard on `layoutAnalyzer == nil` is already
internal, so no outer `if` needed. ~30% per-page speedup when Surya
is installed (Surya is the long pole at ~1-2 s vs Vision's ~0.5 s).

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

# Tier 9: Conversion-quality push (next batch)

15 ideas the user picked from a 2026-05-07 brainstorm on what
else could make PDF conversion **more effective, more versatile,
and more efficient**. Organized by axis below; the proposed
shipping sequence (5 rounds) follows.

## Effective (output quality)

### Q-Coherence — Document-level coherence pass

**Status**: shipped (Tier 9 / Round 2). New
`ClaudeCoherenceAnalyzer` builds a digest of every chapter
(title + first ~200 chars of body, capped at 8K total chars),
asks Haiku to identify recurring OCR errors that should be
normalized, and returns up to 10 suggestions of the form
`{wrong, right}`. Each suggestion is filtered by a guardrail
(`shouldApply`):

  * Length-ratio bound: `min(|wrong|, |right|) / max(...) ≥ 0.5`.
    Beyond that, the rewrite looks like a different word →
    reject.
  * Document-occurrence floor: `wrong` must appear ≥ 3 times
    in the assembled text. Single-occurrence candidates aren't
    worth a global rewrite + may be legitimate variation.
  * No-collision: `right` must NOT already appear in the
    document. If it does, the document has both forms — applying
    a global rewrite would homogenize legitimate variants.
  * Empty / equal: trivially rejected.

Surviving suggestions apply as case-sensitive global string
replacements across every text-bearing run (and chapter titles).
Run metadata (language, noterefId) is preserved.

Toggle: `cloudFeatures.coherencePass`, default true. Single
Haiku call per book — effectively free.

### Q-Hyphenation — Cross-page hyphenation repair

**Status**: already shipped via `PDFToEPUBPipeline.bridgeBoundaries`
(pre-Tier 9). The post-reflow pass walks adjacent paragraphs in
`[Block]` (across columns and pages), and where the previous
paragraph's tail satisfies `Dehyphenation.shouldDehyphenate`,
joins them dropping the soft hyphen. Same heuristic as
intra-region dehyphenation. Edge cases not covered (heading-to-
paragraph bridging where the next page starts with a heading,
proper-noun continuations the lowercase rule refuses) are
deferred — uncommon and conservative-by-design.

### Q-Metadata — Author / title / ISBN extraction

**Status**: shipped (Tier 9 / Round 2). New
`ClaudeMetadataExtractor` samples the first ~4K chars of the
first 1-2 chapters' body text (chapter cap is hard — front
matter + first body chapter is plenty; deeper into the book
the extractor would mis-identify body sentences as titles), and
asks Haiku to return a JSON object with `title`, `author`,
`year`, `publisher`, `isbn`. Each field is verbatim or null —
the prompt explicitly forbids guessing.

Year normalization extracts a 4-digit substring from
freeform-y values like "© 2003" or "first published 2003".
ISBN normalization strips hyphens / spaces, validates length
(10 or 13 digits with optional `X` check digit on ISBN-10),
uppercases the check digit. Both passes return nil for
malformed values.

`Book` extended with optional `year`, `publisher`, `isbn`
fields. `OPFWriter` emits `<dc:date>`, `<dc:publisher>`, and
`<dc:identifier>urn:isbn:…</dc:identifier>` when present;
absent fields produce no extra OPF lines so user-built books
stay clean.

Toggle: `cloudFeatures.metadataExtraction`, default true. One
Haiku call per book — < $0.001 at Haiku rates.

### Q-Dashes — Em-dash / en-dash / hyphen disambiguation

**Status**: shipped as part of the Round 1 typography pass
(`TypographyNormalizer`). ASCII `--` collapses to `—` (em-dash);
numeric ranges `\d+-\d+` collapse to en-dash via lookaround
regex; isolated single hyphens are intentionally left alone.
Conservative — every rewrite must be uniquely a typography
artifact. Documented limitation: bare-digit phone numbers
(`555-1212`) get caught by the digit-range rule; acceptable
since academic prose rarely contains them and the false-positive
rate on real ranges (years, page numbers, intervals) is far
higher in the no-rule baseline.

### Q-Ligatures — Ligature normalization

**Status**: shipped as part of the Round 1 typography pass
(`TypographyNormalizer`). Decomposes the Latin presentation-
form ligatures (`ﬀ`, `ﬁ`, `ﬂ`, `ﬃ`, `ﬄ`, `ﬅ`, `ﬆ`) to their
letter-pair / triplet forms; strips invisible soft hyphens
(`U+00AD`) that PDF line-break hints leak through. Greek
typographic ligatures and archaic Latin abbreviations remain
deferred — the Latin set is what shows up in actual academic
PDFs; the rest can layer in per-script if a corpus demands it.

## Versatile (more inputs, more outputs)

### V-PDF-Searchable — Searchable-PDF re-export

**Status**: shipped (commit `30a9486`). "Searchable PDF" toggle
in the launcher options emits `<basename>.searchable.pdf`
alongside the EPUB. Source PDF is re-rendered page-by-page with
an invisible OCR text overlay per `TextObservation`; no extra
OCR cost. Font sizing is calibrated so each line's natural width
matches the observation box, avoiding PDFKit's per-character
word-split heuristic. Routes to the configured output folder's
`Books/` subfolder when set.

Same OCR + layout pipeline, output is a clean OCR'd PDF with a
searchable text layer instead of (or alongside) the EPUB. Adds
a "make this scan searchable" workflow that doesn't engage
EPUB chapter splitting + reflow + cover detection — useful when
the user wants to keep the original page layout intact.

**Effort**: ~3 days. PDFKit can build a PDF; the work is
positioning OCR'd text under the rendered glyphs at the right
coordinates. Existing `TextObservation.box` in normalized
coords + page DPI gets us there.

### V-Outputs — Plain-text + Markdown + HTML + DOCX siblings

**Status**: txt + md + html shipped (Tier 9 / Round 4 + commit
`1a89bd5`). DOCX output still deferred to Round 5. Note: DOCX
as an *input* format (DOCX → EPUB) shipped separately via
`DocumentIngest` (commit `0ed2b72`) — that's a different
feature.

`PlainTextWriter` and `MarkdownWriter` both walk a `Book` →
`String`. PlainText: title + author header, chapter titles
underlined with `=`, paragraphs flat, anchors skipped, figures
+ tables summarized as bracketed lines, footnotes in a `Notes`
section per chapter. Markdown: `# title`, `*by author*`,
`*year · publisher*`, `## chapter`, `### sub-section`,
`![alt](images/...)` for figures, GitHub-flavored table
syntax with pipe-escaping, `[^N]: ...` footnote definitions.
`HTMLWriter` emits a single self-contained HTML5 document with
inline CSS, one `<section>` per chapter; opens in any browser
without unzipping the EPUB.

Pipeline emits all three as siblings of the EPUB on conversion.
Best-effort writes (failures don't fail the conversion). The
launcher's `emitSiblingTextOutputs` toggle now reads ".txt +
.md + .html" and controls all three. Sibling files are
regenerated on every editor save (`SiblingRegenerator`) so
external consumers stay current. Lands in per-format subfolders
when a configured output folder is set.

23 new tests across the text + markdown writers covering header
rendering, chapter / paragraph / heading / figure / table /
footnote / anchor handling, pipe-escaping in table cells, and
metadata line rendering.

### V-Trust-PerPage — Per-page embedded-text trust

**Status**: shipped (Tier 9 / Round 4).

User types a 1-based page-range string in the launcher's "Force
OCR pages:" field — `"1-20, 150-160"` syntax, comma-separated
with `N-M` ranges. Empty string keeps the existing global
behavior. New `PageRangeParser.parse(_:)` produces 0-indexed
`[ClosedRange<Int>]`; resilient — malformed tokens (non-numeric,
reversed ranges, zero/negative) skip silently rather than
discarding the whole input.

`PDFToEPUBPipeline.Options.shouldForceOCR(forPageIndex:)`
unifies the gate: returns true when global `forceOCR` is set OR
the page falls inside any per-page range. Replaces the
all-or-nothing global check at three sites (cascade verdict
selection, page-OCR E-Routing trust check, batch prep trust
check). Checkpoint resume also gates on this — a re-run with
new force ranges actually re-processes the affected pages
instead of silently using the previous run's verdict.

UI: dedicated "Force OCR pages:" text field above the toggle
row in the launcher options, with placeholder "e.g. 1-20,
150-160" and help text explaining the use case (mixed-quality
books — born-digital front matter + scanned appendix).

17 new tests: 13 `PageRangeParserTests` (empty / single page /
single range / multi-token / whitespace tolerance / malformed
skip / negative skip / degenerate same-page range / no merge of
overlaps + format / round-trip) + 4 `OptionsForceOCRTests`
(global override every page, no-force matches nothing, per-page
ranges match only listed pages, additive composition with
global).

### V-Refresh — EPUB refresh (re-OCR)

**Status**: shipped — v1 (commit `991b1bb`) + v2 (commit
`0025c5b`). Document menu → "Re-OCR All Pages With ▸ {engine}"
walks every entry in the page map, re-renders each PDF page,
reflows via the standard pipeline, and splices the result
between `hu-page-N` anchors using `PageContentReplacer`. v2
preserves manual XHTML edits between re-OCR pages — a partial
or cancelled bulk run leaves forward progress that can be kept.
Disabled without an attached source PDF + page-map sidecar
(older or non-Humanist EPUBs). Separate from the single-page
"Re-OCR Current Page" path already in the Tools menu.

Open an existing EPUB, re-run OCR with new settings. Useful
when the user has a poorly-converted EPUB from elsewhere or
wants to re-process with newer engines / Cloud features. Needs
a reverse pipeline: extract source PDF (when sidecar is
present), re-render pages, OCR, rebuild the EPUB while
preserving any user edits to the existing chapters.

**Effort**: ~3 days. Tricky bit is the merge with user-edited
content — could ship a v1 that just rebuilds without preserving
edits, then add merge in v2.

## Efficient (speed, cost, memory)

### E-Batches — Anthropic Batches API for Cloud-mode runs

**Status**: shipped (Tier 9 / Round 3, both steps).

**Step 1** — AI-module primitives. `AnthropicBatchAPIClient`
exposes `submit`, `status`, `awaitCompletion` (poll until ended
with configurable interval + timeout), and `fetchResults`
(decode the JSONL result stream). Wire-format types cover the
submit body (`AnthropicBatchSubmitRequest` with per-entry
`customId` + `params`), the submit / status responses
(`processing_status` enum: `inProgress` / `canceling` /
`ended`), and the result-line union (`succeeded` / `errored` /
`refused` / `canceled` / `expired`). The decoder splits
"succeeded with refusal stop reason" into `.refused` so callers
pattern-match cleanly. Corrupt JSONL lines skip silently —
partial-batch recovery is the point. 12 dedicated tests.

**Step 2** — pipeline integration. New
`dispatchPageOCRViaBatch(...)` plugs into the deferred-append
slot the parallel TaskGroup uses. Three phases:

  * **Phase A** (parallel TaskGroup): `preparePageForBatch`
    per page — trust check (returns final pending if `.trust`),
    else render + Surya layout + figure extraction + build
    Sonnet request via the new `pageEngine.buildBatchRequest`.
    Figure extraction runs here so page images don't need to
    stay alive across the batch wait.
  * **Phase B** (single round-trip): reserve N budget calls
    upfront, build `AnthropicBatchSubmitRequest` with
    `custom_id = "page-NNNNN"` per page, submit, await
    completion, fetch results. Submission / poll / fetch
    failures fall through to "settle each page's partial as
    final" — empty pages emit instead of aborting the
    conversion.
  * **Phase C**: walk results by `customId`, parse each via
    `pageEngine.parseBatchMessage`, record usage on the
    budget, fill in the blocks/footnotes on the matching
    partial. Refused / errored / canceled / expired results
    leave the page empty (same posture as a synchronous
    Sonnet failure). Result lines whose customId doesn't
    match any submitted page (corrupt or unknown) get
    silently skipped; the page's partial becomes its final.

`ClaudePageOCREngine` gained `buildBatchRequest`,
`parseBatchMessage`, and `recordBatchUsage` to share the
request shape + parser between sync and batch paths. The
existing `recognize` is now a thin wrapper around the same
internals.

Activated via `cloudFeatures.useBatchAPI` (default off — opt-in
because async wall time changes the conversion experience).
When the toggle's on AND `useClaudePageOCR` is on AND a fresh
Sonnet page exists, the dispatch routes through batches; the
synchronous TaskGroup path remains as the fallback (used when
batches off, when there are no fresh Sonnet pages, or when
the API key is missing).

### E-Parallel — Parallel page processing

**Status**: shipped (Tier 9 / Round 3).
`cloudFeatures.parallelPageOCRConcurrency` (default 1, decode-
clamped to ≥ 1) drives the page-OCR Sonnet path through a
bounded `withThrowingTaskGroup`. Concurrency=1 preserves the
original serial rhythm; bumping to 4-8 cuts wall time roughly
proportionally on bulk runs (a 400-page book at concurrency=4
drops from ~50 minutes to ~13 minutes; Sonnet is the long
pole, Build-tier RPM accommodates 4-8 concurrent calls
comfortably).

Architecture (deferred-append):
  * New `PendingPageOCR` struct captures everything one page's
    page-OCR pass produces (anchor + blocks + footnotes +
    figures + verdict + bounds + sonnet-success flag).
  * Per-page work extracted into `runPageOCRPage(...)` —
    handles E-Routing trust check, render, parallel Surya
    layout, the Sonnet call, and figure extraction. Throws
    only on cancellation; Sonnet failures absorb into
    `sonnetSucceeded == false` on the returned value.
  * The `convert` for-loop's page-OCR branch now defers via
    `pageOCRPageIndices.append(i); continue` — no inline
    appends to the per-document accumulators.
  * Checkpoint-restored pages also route through
    `pageOCRPendingByIndex` so sparse-checkpoint cases
    (pages 0, 2, 4 done; 1, 3 fresh) still emit in document
    order.
  * After the for-loop, a bounded TaskGroup dispatches
    `runPageOCRPage` for fresh indices; checkpoint-restored
    indices skip dispatch (they're already in the dict).
  * Final assembly walks page-OCR indices in ascending order
    to populate `claudePageBlocks` / `claudePageAnchors` /
    `claudePageFootnotes` / `claudePageFigureAssets` (with
    sequential asset IDs assigned at assembly time) + write
    checkpoints + emit progress.

Surya sidecar pooling (the `P-Surya-Pool` half of E-Parallel)
remains separately deferred — each pool member loads ~1.3 GB
of weights, so the memory tradeoff is worth a dedicated
decision.

E-Batches step 2 (pipeline integration) plugs into the same
deferred-append architecture: the dispatch path becomes
"submit batch instead of TaskGroup; on completion, fill
`pageOCRPendingByIndex` from result lines." Single new code
path inside the existing post-loop dispatch.

### E-Warm — Surya sidecar warm-on-launch

**Status**: shipped (Tier 9 / Round 1). `HumanistApp.init`
fires a detached background task that calls
`await SuryaConnection.shared?.bridge.startIfNeeded()`. Spawns
the Python sidecar + waits for Surya's hello message during
onboarding so the first PDF conversion doesn't pay the ~5-15s
spawn cost. Fire-and-forget — failure (Surya not installed)
silently falls back to the existing Vision / Tesseract path.
Model weights still load lazily on first inference, but Python
startup + imports are the bulk of the latency.

### E-Routing — Adaptive Cloud routing per page

**Status**: shipped — v1 (Tier 9 / Round 3). When
`useClaudePageOCR` is on and `cloudFeatures.adaptivePageRouting`
is on (default true), each page runs `EmbeddedTextExtractor` +
`EmbeddedTextQualityScorer` first. Pages scoring `.trust` skip
the Sonnet call entirely and emit reflowed embedded text via
`ParagraphReflow`. Pages scoring `.reocr` fall through to the
existing Sonnet path. `forceOCR` overrides routing (always
Sonnet); turning the toggle off restores every-page-Sonnet
behavior.

Saves ~$0.04 per page on born-digital pages within mixed-
quality books. A 400-page book that's 50% born-digital + 50%
scanned drops from ~$16 to ~$8. Per-page verdicts feed
`ConversionStats.pagesTrustedEmbeddedText` so the queue UI's
post-conversion summary shows what routing actually picked.

Beyond v1: more granular per-page routing (Sonnet only on
table-heavy pages, cascade with Claude tail on hard-OCR pages,
Vision only on clean-Vision pages) requires a richer per-page
profiler. v1 tackles the highest-payoff case (skip-Sonnet-for-
trust); the rest can layer on later if a corpus shows the
need.

### E-Cache-Audit — Prompt cache reuse audit

**Status**: shipped (Tier 9 / Round 1). Audit finding: every
Claude feature was passing `system: .plain(...)`, which sends
the system prompt as a bare string with no `cache_control`
breakpoint — the prompt-cache prefix never hit. Switched all
six (`ClaudeOCREngine`, `ClaudePageOCREngine`,
`ClaudePostProcessor`, `ClaudeTableExtractor`,
`ClaudeChapterClassifier`, `ClaudeTOCParser`) to
`system: .cached(Self.systemPrompt, ttl: .oneHour)`. First
call writes the cache; subsequent calls in the 1h window read
it for a 90% input-cost discount. 1h TTL covers long bulk
runs that span multiple cache windows, plus cross-book reuse
in a session.

## Observability / Iteration

### O-Diff — Conversion diff tool

**Status**: shipped. Tools → Compare EPUBs… picks two EPUBs,
runs `EPUBDiffer` (chapters paired by spine position, paragraphs
diffed via `CollectionDifference`), and opens a window with:
a chapter navigator sidebar (change-count badge on each entry);
a side-by-side detail pane with removals highlighted red and
additions green, paired 1-to-1 within each run of changes; a
"Show unchanged" toolbar toggle; and a "Save Report…" button
that writes a plain unified-diff `.txt` to disk. Per-page CER
and cost/time comparison are deferred (need ground-truth
infrastructure and conversion-stats sidecar respectively).

Run two conversions of the same PDF with different settings
(Cloud vs Private, two different cascade thresholds, two
different prompts) and surface a side-by-side diff: per-chapter
text diff, per-page CER if a ground truth is available, cost +
time comparison. Catches regressions, helps tune thresholds,
lets the user A/B Cloud vs Private before committing.

**Effort**: ~3 days. Diffing structured EPUBs needs a
tree-aware diff (per-chapter text + nav + metadata), not just
file-level.

---

## Proposed shipping sequence

Five rounds, smallest-leverage-first per round, with each round
committable independently. The earlier rounds compound: warming
the sidecar speeds every later test cycle; better metadata
flows into the Library window; the typography pass affects every
output format below. The user revises this sequence before
shipping.

### Round 1 — Quick wins (~2 days total) — **shipped**

Small, isolated improvements that compound across every
subsequent round.

1. ~~**E-Warm**~~ shipped — sidecar warm-on-launch via
   detached `startIfNeeded()` task in `HumanistApp.init`.
2. ~~**E-Cache-Audit**~~ shipped — every Claude feature now
   uses `.cached(...)` instead of `.plain(...)` for the system
   prompt; 1h ephemeral TTL.
3. ~~**Q-Hyphenation**~~ already shipped pre-Tier 9 via
   `bridgeBoundaries`; ~~**Q-Dashes**~~ + ~~**Q-Ligatures**~~
   shipped as `TypographyNormalizer` (post-reflow, before
   chapter splitting): Latin ligature decomposition + soft-
   hyphen strip + `--`→`—` + `\d+-\d+`→`\d+–\d+`.

### Round 2 — Metadata + coherence (~2.5 days) — **shipped**

4. ~~**Q-Metadata**~~ shipped — `ClaudeMetadataExtractor` runs
   one Haiku call over the front matter; `Book` gains `year` /
   `publisher` / `isbn` fields; OPF emits `<dc:date>`,
   `<dc:publisher>`, `<dc:identifier>urn:isbn:…`.
5. ~~**Q-Coherence**~~ shipped — `ClaudeCoherenceAnalyzer`
   runs one Haiku call over a digest of every chapter; returns
   up to 10 wrong→right pairs; guardrail rejects suggestions
   that fail length-ratio / occurrence-count / no-collision /
   empty-or-equal checks before applying as global find/replaces.

### Round 3 — Cost + speed wins (~7 days) — **shipped**

Heavier lifts, but each one independently valuable. Order
within the round picks **Routing first** (removes calls before
batching them); then **Batches** (discounts what's left); then
**Parallel** (compounds with both). Pulled ahead of the output-
format round per user revision (2026-05-07): cost / speed wins
amortize across every subsequent test cycle and Cloud-mode run,
so it's worth eating the heavier lift earlier.

6. ~~**E-Routing**~~ shipped (Tier 9 / Round 3) — page-OCR
   path skips Sonnet on `.trust`-verdict pages.
7. ~~**E-Batches**~~ shipped — AI primitives (step 1) +
   pipeline integration (step 2). 50% Sonnet token discount on
   page-OCR runs in exchange for async wall time (~1-5 min
   typical, capped at 24h). Routes through
   `dispatchPageOCRViaBatch` when `cloudFeatures.useBatchAPI`
   is on.
8. ~~**E-Parallel**~~ shipped (Tier 9 / Round 3) —
   `cloudFeatures.parallelPageOCRConcurrency` drives a bounded
   TaskGroup over the page-OCR loop via deferred-append
   architecture. Concurrency=1 preserves serial behavior;
   higher values cut bulk-run wall time near-proportionally.
   E-Batches step 2 plugs into the same deferred-append slot.

### Round 4 — Output formats + ingestion options (~2 days) — **shipped**

9. ~~**V-Outputs (txt + md)**~~ shipped — `PlainTextWriter` +
   `MarkdownWriter` emit as siblings of the EPUB on conversion;
   `emitSiblingTextOutputs` toggle in launcher (default on).
   DOCX still deferred to Round 5.
10. ~~**V-Trust-PerPage**~~ shipped — `PageRangeParser` + new
    "Force OCR pages:" field in the launcher (1-based ranges,
    e.g. "1-20, 150-160"). Per-page gate replaces the global
    `forceOCR` check at every site; checkpoint resume respects
    the gate so re-runs honor new ranges.

### Round 5 — Heavier features (~12 days)

Substantial new flows; ship in whatever order matches actual
demand. Conversion diff is the meta-tool — useful for
validating Rounds 1-4 didn't regress anything.

11. ~~**V-PDF-Searchable**~~ shipped (commit `30a9486`).
12. ~~**V-Outputs (DOCX)**~~ shipped — `.docx` sibling via `NSAttributedString`/officeOpenXML; split into separate `.html + .docx` toggle from `.txt + .md`.
13. ~~**O-Diff**~~ shipped — side-by-side chapter diff window.
14. ~~**V-Refresh**~~ shipped (commits `991b1bb`, `0025c5b`).

**Total**: ~26 days of work across 14 commits / features. Ships
in roughly 3-4 person-weeks of focused effort if pursued
sequentially; the Round 1-2 items can interleave with anything
else since they're small and independent.

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
  Line, Split / Merge / Rename / Regenerate TOC, drag-and-drop
  chapter reorder in sidebar, Find in All Files, Validate EPUB
  (epubcheck), spellcheck, smart quotes, formatting toolbar,
  **Customize Style** (per-book font/size/theme), **WYSIWYG
  editor pane** (⌘4, contenteditable WebView with formatting
  toolbar + CSS rendering), **chat-with-book pane** (⌘5, BM25
  retrieval + Haiku/Sonnet + streaming + citation chips +
  persistent transcript), **save-on-close dialog**,
  **WYSIWYG oscillation fix**, **source-to-WYSIWYG sync on
  save**, **visible pane dividers + Equalize Panes**.
- **Sibling outputs**: `.txt` + `.md` + `.html` emitted on
  every conversion and regenerated on every editor save;
  **Searchable PDF** sibling (invisible OCR overlay); all routed
  to per-format subfolders when a **configurable output folder**
  is set in Settings.
- **Non-PDF inputs**: TXT / MD / RTF / HTML / DOCX / ODT → EPUB
  via `DocumentIngest`; headings, bold, italic preserved.
- **File Tools menu**: PDF Join/Split + EPUB Join/Split, no
  editor window required.
- **App theme system**: five named palettes (System, Parchment,
  Scholarly, Nocturne, Studio) in Settings → Appearance.
- **Library**: cover thumbnails per row; bulk find/replace.
- **Launcher quality-of-life**: pause/resume queue, drag-reorder
  queued jobs, finished-jobs History disclosure, dedicated full-
  queue window (⇧⌘Q).
- **Library**: dedicated browser window (⇧⌘L) listing every
  converted EPUB with sortable columns + language filter +
  cross-book bulk find/replace.
- **Tier 9 / Round 5 fully shipped**: V-PDF-Searchable, V-Refresh,
  V-Outputs (DOCX), O-Diff side-by-side viewer.
- **`humanist-cli`**: convert / compare / validate from the shell;
  same engines as the .app, scriptable for CI and automation.
- **Local chat backend** (Ollama + Gemma 4 26B MoE): chat-with-book
  runs entirely on-device, no API key required.
- **Setup wizards** for Surya / Tesseract / Ollama replace bundled
  runtimes; .app bundle stays at ~14 MB.
- **P-Vision-Concurrency**: Vision OCR + Surya layout run in
  parallel via `async let`, ~30% per-page speedup when Surya
  is installed.
- **Swift 6 strict concurrency mode** (`C-Swift6-Migration`):
  `Package.swift` flipped to `swiftLanguageModes: [.v6]`; full
  test suite (822 tests) clean. Earlier prep (commit `abaa918`)
  cleared the easy three (`DocumentProfiler`, `TwoUpDetector`,
  `SidecarBridge`); this round cleared the rest — `RegionAwareReflow`'s
  8 debug statics refactored to a `Diagnostics` return struct,
  `DOCXWriter`'s NSFont/NSAttributedString constants made computed,
  `LoadedPDF: @unchecked Sendable` with a defended invariant,
  `PDFToEPUBPipeline` TaskGroup closures use captured method
  references, `QueueViewModel`'s `runner` capture and
  `supportedLanguages` access fixed, plus a handful of cascade
  Sendable conformances. One audited `nonisolated(unsafe)` for
  the deinit-only `pdfPageObserver` token. Compiler help is now
  free quality; every future Swift toolchain tightens the screws
  at build time rather than at 3 AM.
- **Hybrid chat retrieval** (`R-Chat-Embeddings`, commits `452daeb`
  / `a421161` / `1d4cb71`): BM25-only chat replaced with paragraph-
  granularity BM25 + embedding cosine fused via RRF. Four
  embedding backends: Apple NLEmbedding (default, free, offline),
  Ollama (local, `nomic-embed-text` recommended), Voyage AI
  (`voyage-3` / `voyage-3-lite`), and Gemini Embedding 2
  (`gemini-embedding-002` with Matryoshka 768/1536/full output).
  Per-book sidecar caches vectors keyed by per-paragraph SHA-256;
  a save re-embeds only changed paragraphs. Generalized the
  Anthropic key store into `KeychainAPIKeyStore` so adding the
  Voyage + Gemini key types was a 30-line shim each. 13 new
  tests pin the cosine math, paragraph extractor, sidecar
  round-trip, and RRF fusion.

**Next, in roughly this order:**

1. **R-Chat-Graph-Lite** — successor to R-Chat-Embeddings. Adds two
   graph primitives the embedding layer can't do (a hierarchical
   structure index for variable-granularity retrieval and a light
   entity index across the library via Apple's on-device
   `NLTagger`), plus the multi-book chat scope deferred from
   R-Chat-Embeddings. ~4-5 days. All primitives extend the per-book
   embeddings sidecar; all run free / on-device. Citation graphs
   and full GraphRAG explicitly out of scope.
2. **R-Library-Chat** — promote the library window to a first-
   class surface with its own embedded chat pane so cross-corpus
   questions don't require opening an anchor book first. ~1-1.5
   days. Reuses the multi-book retrieval path; adds a
   `LibraryChatViewModel` and a split-view layout in the library
   window. Bundles the window-switcher menu commands (Show
   Converter / Show Library / Show Editor / Show Queue) since the
   library window becomes a primary navigation target.
3. **E-Vision-Modes** — Manuscript mode (Claude Opus 4.7,
   diplomatic transcription posture) and Early Print mode
   (Gemini 3.1 Pro, fluent normalization with strong typeface
   priors) as per-conversion choices in the launcher. Each mode
   routes pages through a flagship vision model with a content-
   tuned prompt instead of the default printed-book pipeline.
   ~2-3 days after a one-day validation spike (CLI comparison
   on hand-corrected ground truth) confirms the model picks.
   Both modes are 4-5× the cost of the default print mode but
   produce qualitatively different output for content the cascade
   can't handle well.
4. **R-Chat-Polish** — small UX gaps in the chat / embedding
   surface (bulk-index command, per-book rebuild button, fallback
   visibility, paragraph-level citation jumps, retrieval debug
   surface, tunable knobs, window-switcher menu commands). Each
   item independently shippable in 30 minutes to 2 hours; pick
   whichever bites hardest. Can interleave with other work.
5. **Distribution polish** — see `RELEASES.md`. Need a Developer
   ID Application certificate (Apple Developer Program, $99/yr),
   then notarization → DMG → GitHub Releases. ~3 days of work
   gated on the cert.
6. **P-Greek-Quality** — ground-truth measurement of Tesseract
   polytonic-Greek CER. Pure measurement task; only needs
   implementation work if CER comes back > 5%.
7. **Stretch / speculative items in Tier 8** if a specific need
   surfaces — Apple Foundation Models polish for chapter
   classification (macOS 26 ships them on-device), custom
   footnote styles, audio output via `AVSpeechSynthesizer`.

Phase 9 (RTL / Hebrew / Syriac / Coptic) is deferred indefinitely
— corpus doesn't justify the bidi-rendering and per-script
accuracy lifts.
