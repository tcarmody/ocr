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

## Status snapshot (as of 2026-05-17)

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

**Done — Library workflow polish** (R-Library-Chat-Plus Tier 1):
- **Chat with Selected**, **Suggested follow-ups**, **Long-form
  synthesis toggle**, **Per-book exclusion** (commit `7c2a879`):
  ad-hoc subset scoping, `[follow-ups]…[/follow-ups]` model
  contract + parser + clickable buttons, doc.text toggle that
  bumps `maxTokens` to 2500 + lengthens guidance, citation-chip
  context-menu deny-list applied via `excluding:` on
  `LibraryEmbeddingIndex.search`.
- **Collections** (commit `e443772`): durable named book
  groupings on `LibraryStore` (`BookCollection`); toggleable
  left sidebar in the Library window; row context menu
  "Add to Collection ▸ …"; filter bar swaps "Chat with
  Selected" for "Chat with {Collection} (N)" when a collection
  is the active filter and no rows are selected. 15 new
  `LibraryStoreTests` cover the mutations + the legacy-load
  + membership-pruning paths.

**Done — Auto-generated Collections Phase 1** (R-Auto-Collections):
- **`BookConversionType`** enum (print / earlyPrint / manuscript
  / digital) stamped on `LibraryEntry.conversionType` at
  conversion (JobRunner) + import (EPUBImporter) time.
  Sibling-PDF heuristic backfills legacy entries on load.
- **`LibraryEntry.author`** field populated from `<dc:creator>`
  at catalog time alongside title.
- **`AutoCollectionSource`** discriminator on
  `BookCollection`: `.byType` or `.byAuthor` for auto-
  generated, nil for manual.
- **`LibraryAutoCollections.refresh(library:)`** materializes
  Type + Author collections from current catalog state.
  Configurable author threshold (Settings → Conversion;
  default 3). Idempotent — re-runs preserve auto-collection
  ids so SwiftUI selection survives refresh. User-created
  collections never touched.
- **Library window sidebar** grows three grouped sections:
  "My Collections", "Auto: by Type", "Auto: by Author".
  Auto-collections get category icons + hide
  Rename/Delete (regeneration would clobber edits).
- **10 new `LibraryAutoCollectionsTests`** cover bucketing,
  threshold honoring, idempotent ID preservation,
  user-collection survival, Codable legacy decode.

**Done — Auto-Collections Phase 2** (R-Auto-Collections /
L-Foundation-Models Phase 4):
- **`BookGenre`** enum (32 cases): poetry, drama; 7 fiction
  sub-genres (Literary / Fantasy / Sci-Fi / Mystery / Romance
  / Historical / General); mathematics; 5 science sub-genres
  (Physics / Chemistry / Life Sciences / Earth & Astronomy /
  General); 3 technology sub-genres (Computing / Engineering
  / General); philosophy, religion, history, biographyMemoir,
  linguistics, arts; 4 social-science sub-genres; reference,
  education, howTo, travel, children, uncategorized.
  Computed `topLevel` / `leafName` / `collectionName`
  properties so sub-genres render as "Fiction: Fantasy" while
  single-level genres stay plain ("Philosophy").
- **`BookGenreClassifier`** in Pipeline — AFM-backed,
  schema-guided enum constraint, takes title + author +
  ~600-char opening text, returns one `BookGenre`. Instruction
  text covers disambiguation cues for tricky cases (historical
  fiction vs. history, scientist memoir vs. science, etc.).
- **LibraryEntry.genre** field with `decodeIfPresent` legacy
  fallback. `recordConversion` carries it through; new
  `setGenre(_:for:)` mutator powers the backfill flow.
- **EPUBImporter** runs the classifier alongside the existing
  metadata + chapter passes; same AFM gating, same cost
  shape. Books imported get classified at import time.
- **`LibraryAutoCollections.classifyMissingGenres`** backfill
  for the historical catalog: walks unstamped entries, opens
  each EPUB, samples front matter, classifies. Progress
  callback + cancellable. ~30-50 min for 1000 books on AFM's
  2-3 s/book pace.
- **Library window UI**: "Classify missing genres" button
  (`wand.and.stars`) next to the existing Refresh button.
  Progress sheet (`ClassifyGenresProgressSheet`) mirrors the
  bulk-index sheet's shape. Fourth sidebar section
  "Auto: by Genre" sorts by top-level then leaf so the flat
  list still reads grouped.
- **16 new tests** across `BookGenreTests` (taxonomy
  invariants, computed-property correctness, JSON round-trip)
  and 5 new tests added to `LibraryAutoCollectionsTests`
  (genre-collection generation, sort order, `setGenre` mutation,
  legacy LibraryEntry decode without genre).

**Done — Manuscript + Early Print OCR** (E-Vision-Modes v1):
- **`ClaudePageOCREngine.Mode`**: three-way enum.
  `.typeset` (Sonnet 4.6, original Claude OCR path),
  `.earlyPrint(typeface:)` (Sonnet 4.6, normalizing-posture
  prompt for 15th–18th c. printed books), `.manuscript(hand:)`
  (Opus 4.7, diplomatic-posture prompt for handwriting).
  Branches model + system-prompt addendum; the base XHTML
  output schema stays shared. Engine factory routes based on
  three launcher flags (`useClaudePageOCR`, `useEarlyPrintMode`,
  `useManuscriptMode`); manuscript wins when flags collide.
- **`ManuscriptHand`** (5 cases): auto / diplomatic /
  roundHand / cursive / contemporaryInformal. Diplomatic
  preserves original spelling + expands scribal abbreviations
  with `<em>`; roundHand keeps period spelling +
  capitalization; cursive does light normalization with
  strikethrough preservation; contemporaryInformal is
  reading-friendly.
- **`EarlyPrintTypeface`** (4 cases): auto / romanAntiqua /
  blackletterFraktur / italic. Fluent normalization across
  all: silent long-s → s, u↔v + i↔j per modern convention,
  standard ligature expansion. Preserves period spelling +
  capitalization otherwise. Blackletter prompt covers
  German-specific characters (eszett ß, round-r ꝛ, umlauts).
- **Pivoted from Gemini for Early Print** — the model wasn't
  the lever; the prompt's normalizing vs. diplomatic posture
  is. Sonnet + tuned prompt delivers the same contrast at
  fraction of implementation cost.
- **`opus4_7` model constant** added to `AnthropicModel`;
  pricing entry already existed.
- **Launcher UI**: three mutually-exclusive toggles in row 2
  ("Claude OCR ($$$)", "Early Print ($$$)", "Manuscript
  ($$$$)") with sub-picker row that appears below for
  Manuscript (Hand:) or Early Print (Typeface:). Per-job,
  not persisted to Settings.
- **Codable round-trip**: `ConversionOptions` adds
  `useManuscriptMode` / `manuscriptHand` / `useEarlyPrintMode`
  / `earlyPrintTypeface` with `decodeIfPresent` so legacy
  queued jobs still load.
- **17 new `ManuscriptModeTests`** cover the three-way Mode →
  model routing, prompt composition, per-hand + per-typeface
  distinctness, normalization-posture invariant for Early
  Print, German-specific blackletter conventions.

**Done — Multi-machine sidecar + alias sync** (R-Library-Sync Phase B):
- **`EmbeddingsSidecarStore` API change**: `libraryID: UUID?`
  parameter routes writes to UUID-keyed paths when set
  (sharing on → `<outputRoot>/.humanist/Embeddings/<uuid>.json`,
  sharing off → `<appSupport>/<uuid>.json`) and to legacy
  SHA-keyed paths otherwise. Reads walk a candidate chain so
  existing SHA-keyed sidecars stay usable during the migration
  window. Every consumer threaded: `BookSidecarBuilder`,
  `LibraryIndexBuilder`, `EPUBImporter` (looks up freshly-
  created entry's id after `recordConversion`),
  `LibraryEmbeddingIndex`, `LibraryEntityIndex`,
  `BookChatViewModel` (uses `OpenRouter.library` to resolve
  URL → UUID at each sidecar access).
- **`AliasDictionaryStore.resolveStoreURL`**: same shape —
  `<outputRoot>/.humanist/aliases.json` when sharing on, else
  Application Support. Single file, simple location swap.
- **`LibrarySyncMigration.runFull(library:)`**: composite
  helper that runs the Phase A catalog move + walks every
  catalog entry to copy SHA-keyed sidecars to UUID-keyed
  locations + copies aliases. Idempotent on every step.
  Settings activation prompt surfaces sidecar / alias counts.
- **Auto-catalog on editor-open**: `EditorViewModel`
  auto-catalogs an opened book that isn't already in the
  library so BookChatViewModel has a stable UUID for sidecar
  keying. Uses canonical-URL dedup (no-op for known books).
- **18 new tests** across `EmbeddingsSidecarStoreKeyingTests`
  (writeURL routing, read fallback chain, write+read
  round-trip) and `LibrarySyncTests` (migration sidecar +
  aliases copy, idempotent re-runs).

**Done — Multi-machine catalog portability** (R-Library-Sync Phase A):
- **`relativePath` on `LibraryEntry`** — populated when the EPUB
  sits under the configured output root. Persisted alongside the
  absolute URL via `decodeIfPresent` so legacy catalogs round-
  trip cleanly.
- **`LibraryStore.resolveAgainstOutputRoot(_:)`** — rewrites each
  loaded entry's `epubURL` to `<currentRoot>/<relativePath>` when
  sharing is on. The portability invariant: same JSON, different
  root, correct local paths.
- **In-root catalog location** — `<outputRoot>/.humanist/library.json`
  when sharing is on. `LibraryStore.resolveStoreURL()` picks the
  destination at init based on the Settings toggle.
- **`LibrarySyncMigration.run()`** — one-shot copy of the catalog
  from Application Support to the in-root location, with idempotent
  re-runs and a backup left behind. Surfaces a clear message in
  the Settings activation flow (moved / already-migrated /
  rootMissing / nothingToMigrate / failed).
- **Settings → Conversion → Library sync** section gates the
  toggle on a configured output folder + documents the relaunch-
  to-apply step. Phase B (sidecar UUID rekey) is named so testers
  understand library chat won't recognize indexes on the second
  machine until that ships.
- **8 new `LibrarySyncTests`** cover the relativePath round-trip,
  the resolution-against-new-root invariant, no-op behavior when
  no root is configured, and the migration's three terminal
  states.

**Done — Existing-EPUB on-ramp** (R-EPUB-Import v1):
- **`EPUBImporter`** + **`ParagraphAnchorInjector`** +
  `ImportEPUBProgressSheet` + `BookSidecarBuilder` (split out
  from `LibraryIndexBuilder`): File → Import EPUB into Library…
  (`⇧⌘I`) opens a multi-select `.epub` picker, then per-book
  runs open → inject `hu-p-N-M` anchors where missing → save →
  repack into Books/ → catalog → build embedding sidecar.
  Idempotent on re-import (anchor injection is a no-op for
  already-anchored books; catalog row updates in place via
  canonical-URL match). 13 new `ParagraphAnchorInjectorTests`
  cover the rewriter edge cases (XML quirks, mixed case, single
  vs. double quoted attributes, `xml:id` / `data-id`
  look-alikes). v1.1 follow-up adds folder + drag-drop import
  (`EPUBImporter.expandSources` walks directories recursively)
  and AFM metadata extraction on import — title + author lift
  out of the first ~4 KB of stripped front-matter, write back
  through `OPFReader.Metadata`'s new public initializer.
  v1.2 adds AFM chapter classification on import via a
  minimal-Chapter sampler + the new `BodyTypeInjector`
  (`epub:type` written into the `<body>` opening tag,
  publisher-set labels preserved). v1.3 extends
  `OPFReader.Metadata` with year / publisher / ISBN slots and
  teaches `EPUBBookSaver` to write them — ISBN goes in as a
  separate `<dc:identifier>urn:isbn:…</dc:identifier>` so the
  package's unique-identifier stays untouched. Coherence pass
  still deferred for imported EPUBs (needs full XHTML →
  Chapter IR parser + round-trip fidelity work).

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

**Done — Library chat performance (2026-05-13)**:
- **Embeddings off iCloud** (commit `565203c`). The
  `EmbeddingsSidecarStore`'s `sharedRootEmbeddingsDir` path
  is gone; UUID-keyed sidecars always live in
  `~/Library/Application Support/Humanist/Embeddings/`,
  regardless of the share-library-across-machines toggle.
  Embeddings at scale (53 GB across 1,212 files for the
  current corpus) blew well past iCloud Drive's design
  envelope and made every federated-index rebuild a multi-
  minute stall via metadata-coordinated reads.
  `EmbeddingsCloudMigration.runIfNeeded` ran on first launch
  after the commit and moved every iCloud sidecar to local
  Application Support (1,212 files, ~53 GB; iCloud dir
  empty afterwards). Idempotent via a UserDefaults flag.
  The share toggle still covers `library.json` + aliases —
  small enough that iCloud handles them gracefully.
- **On-disk federated index cache** (commit `caae52f`). New
  `FederatedIndexCache` serializes the assembled
  `(LibraryEmbeddingIndex, LibraryEntityIndex)` to a single
  binary file under Application Support. Cache key: SHA-256
  over (backendIdentifier, dimension, sorted [libraryID,
  sidecar mtime, sidecar size]) — `stat`-only, cheap. VM
  init loads the cache; misses rebuild + fire-and-forget
  save. Result: library-chat cold-start dropped from
  multi-minute to seconds when the fingerprint matches.
  Cache wiped on chat-pane refresh + Settings "Clear all".
  13 tests cover round-trip, drift rejection, corruption
  handling.
- **Binary sidecar format** (commit `a913e70`). New `.emb`
  format: 8-byte magic + version + JSON header (paragraph
  metadata + hierarchy + entities, debuggable with hex tools)
  + packed Float32 vector blob. Defensive decoder rejects
  short reads / bad magic / blob-size mismatch.
  `EmbeddingsBinaryUpgrade.runIfNeeded` ran on first launch
  and re-encoded every legacy `.json` sidecar to `.emb`,
  deleting the original only after a successful atomic
  write. Resume-safe via the stale-json-next-to-fresh-emb
  detection branch. Disk dropped 53 GB → 35 GB (34%
  reduction; the JSON header still dominates the savings
  ceiling, but the Float32 blob saves substantial bytes per
  file). 14 tests cover round-trip, corruption, idempotent
  upgrade.

**Done — Auto-scan / multi-Mac coordination (2026-05-13)**:
- **Source-hash tombstones** (commit `d6be366`). New
  `LibraryStore.rejectedSourceHashes: Set<String>` —
  persisted in `library.json`, sync-friendly. The remove
  dialog grows a "Trash & Don't Re-scan Source" button that
  trashes the EPUB AND folds its source hashes into the
  rejection set. `InputFolderScanner` becomes two-phase:
  cheap path-based check first; survivors get SHA-256 hashed
  off-main and tested against
  `library.isSourceHashKnownOrRejected`. Per-path hash cache
  keyed on (mtime, size) keeps repeat scans free.
  In-flight scan task is cancellable so a Finder copy-storm
  doesn't stack redundant work. 8 new tests.
- **In-flight claims** (commit `6e63351`). New `ClaimMarker`
  struct (`sourceHash`, `hostName`, `claimedAt`) on
  `LibraryStore.claims` — small, sync-friendly, persisted
  alongside entries + collections. `JobRunner.runPipeline`
  stamps a claim before running the pipeline; peers see the
  claim via iCloud catalog sync and skip the same source.
  Stale-claim freshness window (30 min default) gets
  overwritten on takeover + reaped on launch. 14 tests on
  the claim primitives.
- **Source-hash backfill** (commits `4ed2846`, `0d644b2`).
  `SourceHashBackfill.runIfNeeded` walks entries with empty
  `sourceContentHashes` and stamps them. Two probe paths:
  (1) source PDF via `LibraryStore.locateSourcePDF` —
  preferred for converted books (PDF hash matches what the
  auto-scanner sees on re-drops); (2) catalog EPUB as
  fallback — for imports (the EPUB *is* the source) and
  conversions whose PDF source is gone. Bounded
  concurrency (4 SHA-256 streams), single bulk save.
  On the user's library: 100 / 2,209 entries had stamps
  before; 2,209 / 2,209 after — every dedupe query now has
  real data behind it.

**Done — Chapter splitting (2026-05-13)**:
- **TOC-driven splitter** (commit `71e0272`). New
  `TOCDrivenSplitter` runs ahead of `ChapterSplitter` when a
  parsed TOC is available. Walks each TOC entry to a block
  index via the existing page-anchor table + offset
  learning, segments blocks at each boundary. Heuristic
  splitter remains the fallback for scanned-image PDFs and
  books with no parseable TOC. Confidence gate at 50% of
  arabic entries; fuzzy ±2-page lookup catches missing page
  anchors. Solves the Écrits-shape failure (3 H1 section
  dividers vs 44 essay-titles → previously 4 chapters,
  now 42+). 8 tests.
- **Ratio-based level override in ChapterSplitter** (commit
  `24a3d69`). Fallback heuristic splitter now considers
  promoting to a deeper level when (a) deeper level has ≥
  5× more eligible breaks, (b) ≥ 5 absolute, (c) coverage
  spans the document (first break in first third, last in
  last third). No size assumptions — works for poetry,
  short-story collections, dictionaries. Diagnostic
  `levelOverriddenFrom` field surfaces the decision in the
  debug log. 3 tests.
- **Title-matching primary path in TOCDrivenSplitter** (commit
  `2bec9a7`). Page-offset learning produced ambiguous winners
  when page anchors are dense (every PDF page has one, every
  plausible offset ties on match count). The first Lacan
  rescan shifted every chapter by ~10 pages because the
  offset learner picked +0 instead of the correct +10.
  Title-matching keys on the actual OCR'd heading text:
  word-bag containment (≥ 80% of TOC words appear in the
  heading), TOC-order discipline, `canBreakChapter`
  filtering to skip running heads. Diacritic-insensitive,
  digit-strip for OCR'd page numbers in headings ("Functions
  I25 of Psychoanalysis" → matches "Functions of
  Psychoanalysis"). Strategy dispatch via `MatchStrategy`
  enum; debug log shows which path fired. 5 new tests on top
  of the existing 8.

**Done — R-Library-Rescan (2026-05-13)**:
- **Source-PDF probe chain** (commit `0b7f601`). New
  `LibraryStore.locateSourcePDFForRescan(for: LibraryEntry)`
  walks cheap heuristics → OPF `<dc:source>` (requires
  unpacking the EPUB, slow but authoritative) → `priorPaths`
  filtered to `.pdf`. Parses via `URL(string:)` so
  percent-encoded paths decode correctly; rejects non-file
  URIs. 8 tests cover the probe sites + edge cases.
- **End-to-end wiring** (commit `02b1f9a`). Library row
  context menu → "Re-scan with Current Settings…" → probe →
  confirmation dialog (or file picker fallback) → job
  queued. Uses the launcher's current settings — no per-
  rescan sheet (future iteration). New
  `ConversionOptions.bypassDedupe` lets the rescan skip
  the dedupe short-circuit. JobRunner success path
  preserves the user's edited title via canonical-URL match;
  `recordConversion` updates in place, no duplicate row.
  `.bak.epub` snapshot before overwrite for one-click
  rollback. Confirmation dialog warns about unsaved editor
  edits.

**Done — Queue UX (2026-05-13)**:
- **Always-visible Pause/Resume + start-paused-on-launch
  preference** (commit `ea87fa1`). Dropped the
  `hasPendingWork` gate on the launcher's pause button —
  always visible, so the user can pre-emptively pause before
  the auto-scanner picks up new PDFs. New Settings
  "Conversion → Queue → Start paused on launch" preference:
  when on, JobRunner.init forces `isPaused = true` and
  re-stamps the persisted `pausedKey` so the state machine
  keeps a single source of truth. 4 new tests.

**Done — Library window polish (2026-05-13)**:
- **Empty-state explainer for collection ∩ search** (commit
  `7cb69cf`). When a populated library shows zero rows
  because the current filter chain (collection + search +
  language) doesn't overlap, the table renders a
  `ContentUnavailableView` naming the active filters and
  offering one-click escapes (Search All Books, Clear
  Search, Show All Languages). Replaces the silently-blank
  table that previously looked like a data-load bug.

**Done — P-Figure-Fallback: born-digital + scanned figure detection without Surya (2026-05-15)**:
- **PDFImageXObjectDetector** in `PDFIngest`. Walks each page's
  CGPDFContentStream looking for `Do` operators referencing Image
  XObjects, tracks the CTM stack across `q`/`Q`/`cm`, and emits
  pixel-perfect placement bboxes in Vision-normalized coords.
  Coverage filters drop page-sized scan rasters (≥85%) and
  decorative spot illustrations (<2%). Preferred over Surya for
  born-digital `.picture` regions — XObjects give the original
  PDF placement rather than rasterizer-dependent bboxes.
- **VisionFigureDetector** in `Layout`. Runs
  `VNGenerateObjectnessBasedSaliencyImageRequest` against the
  rendered page image; filters detections by minimum page coverage
  (2%) and maximum text-observation overlap (25%); emits
  `LayoutRegion(kind: .picture)` entries. Last-resort fallback for
  scanned books when Surya isn't installed. Quality bound: misses
  small figures, no `.formula`/`.table` distinction.
- **Pipeline merge** in `analyzeLayoutWithRetry` +
  `augmentWithVisionSaliency`. Strategy: PDFKit XObjects always run
  first; overlapping Surya `.picture` regions are dropped in favor
  of the XObject bbox; non-picture Surya regions (text/heading/
  table/footnote/caption) are kept intact; Vision saliency fires
  only when both XObjects and Surya produced zero picture/formula
  regions and a page image is available. Wired into all three
  figure-extraction call sites (main cascade loop, sync page-OCR,
  batch-prep page-OCR).
- **Wizard copy updates** in `WelcomeSheet` + `SuryaSetupSheet`.
  Surya now framed as "strongly recommended for image, table, and
  layout detection," with the absence-mode behavior (PDFKit
  XObjects for born-digital, Vision saliency for scanned)
  documented inline so users understand what they lose by skipping.

**Done — P-Bundled-Tesseract: self-contained Tesseract distribution (2026-05-15)**:
- **Weak-linked dylibs + dlsym runtime gate** (Phase A). Removed
  `link "tesseract"` / `link "leptonica"` directives from the
  CTesseract modulemap; added `-weak-ltesseract -weak-lleptonica`
  to the OCR target's linker settings in `Package.swift`. dyld
  now lets the binary launch when the dylibs are absent. New
  `TesseractOCREngine.runtimeAvailable` probes `dlsym(RTLD_DEFAULT,
  "TessBaseAPICreate")` once on first access; `detect()` gates on
  it before any Tesseract symbol is touched. Every existing call
  site already routed through `detect()` — no callers changed.
  Verified by moving the bundled dylibs aside and confirming the
  app still boots cleanly.
- **Bundled dylibs in `Contents/Frameworks/`** (Phase B). Build
  script (`Scripts/build-app.sh`) gained a step that copies the
  15-dylib closure (libtesseract, libleptonica, libarchive, libpng,
  libjpeg, libgif, libtiff, libwebp, libwebpmux, libsharpyuv,
  libopenjp2, libzstd, liblzma, liblz4, libb2) into Frameworks,
  rewrites every LC_ID_DYLIB + cross-dylib LC_LOAD_DYLIB to
  `@rpath/<basename>` via `install_name_tool`, adds an LC_RPATH of
  `@executable_path/../Frameworks` to the main binary, and signs
  each dylib individually with the same identity used for the
  binary. Bundle grew 20 → 39 MB.
- **Bundled traineddata** (Phase C). eng (4 MB) + grc (2 MB) +
  lat (3 MB) + heb (1 MB) copied into `Resources/tessdata/`;
  `detect()` prefers `Bundle.main.resourceURL/tessdata` before
  falling back to Homebrew paths. Users who want additional
  Tesseract languages (Arabic, Chinese, Japanese, Korean, Sanskrit,
  Coptic, Syriac, etc.) still go through `brew install
  tesseract-lang` and the cascade picks them up automatically.
- **Credits.rtf** updated with attributions for the 13 bundled
  image-format / compression libraries (all permissive: BSD-2 /
  BSD-3 / MIT / libpng / libtiff / CC0 / Public Domain). Tesseract
  Apache 2.0 and Leptonica BSD-2 attributions already existed.
- **Wizard reframed** in the Welcome sheet: with bundled tessdata
  present, the "Set up Tesseract…" branch self-hides via the
  `detect() != nil` gate. The Tesseract setup sheet remains
  available for users who want to install additional languages
  but is no longer the default path.

**Done — Multi-provider page OCR + cascade Stage 2.5 + refusal-rate stats (2026-05-14)**:
- **P-Page-Provider-Choice — Gemini Flash as alternative to Claude
  Sonnet for page OCR** (commits `e11722c`, `8625ed4`). New
  `PageOCREngine` protocol with two concrete impls:
  `ClaudePageOCREngine` (existing Sonnet path) and
  `GeminiPageOCREngine` (Generative Language API). Same XHTML
  output schema parsed by `ClaudePageXHTMLParser`. Provider
  selector in Settings → AI; three choices (Claude Sonnet 4.6,
  Gemini 2.5 Flash, Gemini 3 Flash preview). 2.5 Flash runs
  ~7–10× cheaper than Sonnet on typeset prose with comparable
  quality. 3 Flash is preview status with Pro-tier reasoning;
  `thinking_level` pinned to `"minimal"` so OCR doesn't get
  charged for unused reasoning. Manuscript mode hard-pins
  Claude Opus regardless of provider pick. Batch API stays
  Claude-only — Gemini-selected runs silently fall back to
  the serial TaskGroup. New `GoogleCloudVisionAPIKeyStore`
  (separate from the AI Studio key store — different consoles).
  Per-provider usage attribution in `ClaudeCallBudget`; cost
  estimate updates per provider.
- **P-Doc-OCR-Cascade — Google Document OCR as Stage 2.5**
  (commit `e11722c`). `GoogleDocumentOCREngine` slotted into
  `RegionCascade` between Tesseract and Claude (Cloud Vision
  `DOCUMENT_TEXT_DETECTION`, ~$0.0015/call). Guardrail-gated
  against the prior tier same as Stage 3. Absorbs most of the
  hard-region tail at classical-OCR pricing before falling
  through to Sonnet for the residual. Gated on Cloud mode +
  `googleDocumentOCRInCascade` toggle + Cloud Vision key.
- **Q-Refusal-Rate — per-page refusal classification** (commit
  `a5dd6dc`). New `ProviderStatus` enum threaded through
  `PendingPageOCR` — `.succeeded` / `.refused` / `.empty` /
  `.apiError` / `.budgetExhausted` / `.skippedTrustRouted` /
  `.canceled`. Both engines map their own error shapes via a
  `classify(error:)` protocol method; Anthropic `stop_reason:
  refusal` and Gemini `finishReason: SAFETY / RECITATION /
  PROHIBITED_CONTENT / BLOCKLIST` route to `.refused`.
  `ConversionStats` adds `pagesRefused` / `pagesEmpty` /
  `pagesAPIError` / `refusedPageIndices` (capped at 200) +
  `pageOCRProviderId` + derived `refusalRate`. Summary string
  leads with refusal count + percentage when non-zero;
  `claude-pages.txt` debug header summarizes refused / empty
  / api-error counts with first 50 refused page numbers;
  queue stats tooltip surfaces refusal rate, first 10 refused
  pages (1-based), and breakouts for empty / API error /
  Vision fallback. Per-provider tagging means head-to-head
  Claude vs Gemini refusal numbers on the same book are
  directly comparable.

**Done — Facing-page bilingual detection + tagging (2026-05-17)**:
- **P-Bilingual-FacingPage Phase (a) — detection + cross-link**
  (commits `4b03b6a`, `2319f2c`). New `BilingualLayoutDetector`
  runs post-OCR and classifies each page via a layered cascade:
  Unicode-script ratio for Greek + Hebrew (since
  `NLLanguageRecognizer` has no separate `grc` and folds polytonic
  into modern `el`), a Latin function-word fingerprint (NLR has
  no Latin classifier — Caesar's Gallic Wars opens as Catalan at
  ~50% confidence in the model), and NLR for English / modern
  languages. Detection gates require classical L1 (`grc` / `la`
  / `he` / `el`), ≥10 confidently-classified body pages, ≥25%
  L1 share, and ≥80% adjacent-pair alternation rate. Conservative
  by design — false positives corrupt the EPUB structurally, so
  the gates aim to under-detect rather than over-detect.
  Returned `Layout` carries a symmetric `pagePartners` map
  (`pdfPage → partner pdfPage`) plus per-page language
  assignments + alternation rate. Pipeline plumbs the layout
  through `AssembledBook` → `writeOutputs` →
  `EPUBBuilder.write(facingPageMap:)` as an `anchorId → partner
  anchorId` map (the EPUB module stays free of Pipeline types so
  the dependency direction holds). `XHTMLWriter` emits
  `data-facing-page="hu-page-N"` on the `<span epub:type=
  "pagebreak">` for any anchor with a partner. **Per-book
  escape hatch**: a *Facing-page bilingual* toggle in the
  launcher's "Per-job overrides" disclosure (and CLI
  `--force-bilingual-facing-page`) relaxes the gates — any L1
  language allowed, ≥50% alternation threshold, ≥4 body pages
  — so books that auto-detect misses (modern-language bilinguals
  outside the classical set, alternation broken by heavy
  footnotes, very short bilinguals) still get paired. Forced
  mode still bails on monolingual input so it can't fabricate
  partners. 8 unit tests cover Latin/English + Greek/English
  positive cases, monolingual / non-classical-L1 / too-few-pages
  / broken-alternation negatives, and the forced-mode
  French/English positive + monolingual safety. **Phase (b) —
  parallel chapter-tree reorganization (two parallel chapter
  sequences in one EPUB, dual-tree TOC, "Jump to Facing
  Translation" command) is pending real-Loeb-book testing of
  Phase (a)**; ship-or-revise decision after evaluating
  detected-bilingual rate on the user's corpus.

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

## Sequencing (as of 2026-05-17)

What to work on next, in priority order. The first block is
driven by concrete, currently-felt user needs; the second block
is the "nice to have, build when you reach for it" tier;
everything else is deferred indefinitely unless the situation
changes.

Drivers for the current ordering:
- **Multi-Mac use is real**, not theoretical — the user is
  already running into pain wanting one library visible from
  two machines.
- **Sharing is for testers only** today; a tester needs a
  working `.app` bundle but doesn't need notarization, Sparkle,
  or a hosted DMG.
- **Manuscript material is on the testing roadmap; classical
  Greek isn't** — the manuscript track wins inside
  `E-Vision-Modes`; the Greek-quality spike drops further down.
- **~1,000 existing EPUBs are queued for import**. That number
  pushes everything that turns a raw-imported EPUB into a
  first-class library row way up — without metadata
  extraction + chapter classification on import, a thousand
  catalog rows show filenames instead of titles, and library
  chat sees a thousand un-classified books.

### Near-term — do these first

1. ~~**R-EPUB-Import: Chapter classification on import**~~
   shipped. `EPUBImporter` builds a minimal `Chapter` per spine
   resource (title from first `<h1>` or `<title>`; opening text
   from `<p>` / `<h2>`–`<h6>` / `<blockquote>` / `<li>` up to
   ~800 chars), runs `AppleFoundationModelClassifier`, and
   writes the returned label into each XHTML's `<body>` opening
   tag via the new `BodyTypeInjector` in Pipeline. Existing
   publisher-set `epub:type` attributes are preserved (the
   injector is conservative — a publisher's "afterword" beats
   the classifier's "appendix" guess). `xmlns:epub` namespace
   inlined when the doc lacks it. 26 new tests across
   `BodyTypeInjectorTests` + `EPUBImporterSamplerTests` cover
   the title-extraction, opening-text-sampling, and tag-rewrite
   edge cases.
2. ~~**R-EPUB-Import: Year / publisher / ISBN write-back**~~
   shipped. `OPFReader.Metadata` gained `year` / `publisher` /
   `isbn` slots; the reader parses `<dc:date>` (extracting the
   year prefix from bare-year or ISO-timestamp shapes),
   `<dc:publisher>`, and `<dc:identifier>` (URN-shaped or
   `scheme="ISBN"`/`opf:scheme="ISBN"`, with hyphen stripping
   to digits). `EPUBBookSaver.updateMetadataInPlace` upserts
   year + publisher via the existing `upsertSimpleDC` helper;
   ISBN goes through a new `upsertISBNIdentifier` that adds a
   *separate* `<dc:identifier>urn:isbn:VALUE</dc:identifier>`
   sibling element — the package's `unique-identifier`
   (`<dc:identifier id="bookid">`) is excluded from the match
   candidates so the publishing identity is never silently
   replaced. 11 new `OPFMetadataExtendedTests` cover the
   parse + save round-trip + the ISBN-doesn't-clobber-unique-id
   invariant.
3. ~~**1000-book bulk-import soak**~~ shipped hardening pass.
   The importer is now ready for big-batch runs:
    - **Skip-existing short-circuit**: `importOne` resolves the
      destination URL up front and, when (a) the EPUB already
      exists at that path, (b) the catalog already lists it,
      and (c) either no backend was requested OR the sidecar
      matches the configured backend + dimension + is non-empty,
      returns a `.alreadyImported` result without opening the
      book. Re-running a partial batch turns hours of redundant
      work into seconds of FS checks.
    - **Skip-indexing toggle** in Settings → Conversion → EPUB
      import. When on, `LibraryWindowView.runImport` passes
      `skipIndexing: true` to `EPUBImporter.start`; the
      effective backend gets dropped so the sidecar build step
      is bypassed. The user runs the Library window's bulk-index
      command later (typically overnight) to fill embeddings in.
    - **Mid-book cancellation**: `Task.checkCancellation()` now
      runs between every major step in `importOne` (after open,
      anchor, metadata, classification, save, repack). Cancel
      mid-book responds in seconds instead of waiting for the
      current book's full pipeline. `CancellationError` thrown
      from within breaks out of the batch loop cleanly without
      logging the cancel as a per-book failure.
    - **Skipped count surfaced**: new
      `@Published skippedExisting` counter on `EPUBImporter`;
      `ImportEPUBProgressSheet`'s completion line reads
      "Imported N books. M already imported (skipped). K
      failed." (zero-skip / zero-fail halves hidden in the
      common case). 7 new `EPUBImporterSkipTests` cover every
      branch of `shouldSkipExistingImport`.
   The Library window's table isn't audited for 1000-row
   sluggishness specifically — SwiftUI Table virtualizes rows
   and the `CoverImageCache` decodes thumbnails lazily, so
   performance should hold up; revisit if a real soak surfaces
   issues.
4. ~~**R-Library-Sync Phases A + B**~~ shipped. The catalog,
   embedding / hierarchy / entity sidecars, and alias dictionary
   all travel across machines via a cloud-synced output root:
   - **Phase A** (already shipped earlier this session):
     `LibraryEntry` carries a `relativePath`; `LibraryStore`
     reads `<outputRoot>/.humanist/library.json` and rewrites
     `epubURL` against the current machine's root on load
     when sharing is on.
   - **Phase B**: `EmbeddingsSidecarStore` gained `libraryID:
     UUID?` parameters; sidecars route by UUID to
     `<outputRoot>/.humanist/Embeddings/<uuid>.json` (sharing
     on) or to UUID-keyed Application Support (sharing off).
     Reads walk a fallback chain (UUID-at-root → UUID-at-
     appsupport → SHA-at-appsupport) so existing SHA-keyed
     sidecars stay usable during the migration window. Alias
     dictionary moves to `<outputRoot>/.humanist/aliases.json`
     when sharing is on. `LibrarySyncMigration.runFull(library:)`
     copies the legacy SHA-keyed sidecars + aliases on
     activation; idempotent re-runs are no-ops.
   - **Auto-catalog on editor-open**: every EPUB opened in the
     editor that isn't already in the catalog gets a thin
     entry (URL + title + language from OPF metadata) so the
     sidecar gets a stable UUID for keying. `recordConversion`
     dedups by canonical URL.
   18 new tests across `EmbeddingsSidecarStoreKeyingTests` +
   `LibrarySyncTests` cover the writeURL routing, read
   fallback chain, write+read round-trip, and migration steps.
5. ~~**E-Vision-Modes — Manuscript + Early Print tracks v1**~~
   shipped. `ClaudePageOCREngine.Mode` enum routes one of three
   ways: `.typeset` (Sonnet 4.6, original behavior),
   `.earlyPrint(typeface:)` (Sonnet 4.6 + normalizing-posture
   prompt for 15th–18th c. printed material; four typefaces),
   or `.manuscript(hand:)` (Opus 4.7 + diplomatic-posture prompt
   for handwriting; five hands). Pivoted from Gemini for Early
   Print — prompt is the lever, not the model; Sonnet+prompt
   delivers the same contrast at fraction of implementation
   cost. Three mutually-exclusive launcher toggles + sub-picker
   row. 17 new `ManuscriptModeTests` cover all three Mode
   branches, prompt composition, per-hand + per-typeface
   distinctness, three-way Mode space.

### Soon — pick up when the near-term cools

6. ~~**R-Auto-Collections Phase 2 — Genre via AFM**~~ shipped.
   `BookGenre` enum (32 cases — Poetry / Drama / Fiction (7
   sub-genres) / Mathematics / Science (5 sub-genres) /
   Technology (3 sub-genres including Computing) / six
   humanities top-levels / Social Science (4 sub-genres) /
   five practical top-levels). `BookGenreClassifier` mirrors
   the Phase-1 chapter classifier shape: schema-guided
   `@Generable` constraint, AFM on-device, free. EPUBImporter
   runs it alongside the existing metadata + chapter passes;
   library backfill via a new "Classify missing genres" button
   (`wand.and.stars` icon) walks the catalog with a progress
   sheet + cancel. "Auto: by Genre" sidebar section sorts by
   top-level then leaf so the flat list still reads grouped.
7. ~~**R-Library-Chat-Plus Tier 2 — citation export +
   conversation export**~~ shipped (commit `6c63714`).
   `ChatCitationFormatter` (Chicago note-style with graceful
   fallbacks) + "Export Transcript…" action on both chat panes.
   8 new tests cover the format matrix + bibliography dedup +
   transcript shape. Pinned passages and ask-each-book mode
   remain in the "Earn when you need it" tier — useful but
   not load-bearing.
8. ~~**R-EPUB-Import: Coherence pass on imports**~~ shipped
   2026-05-12 via Option B (text-node-only path —
   `CoherenceDigestSampler` + `XHTMLTextReplacer` +
   `EPUBImporter.runCoherencePass`). Skipped the doc's
   originally-spec'd XHTML → Chapter parser since the apply
   step only needs text-content replacement; no Chapter IR
   round-trip means publisher formatting survives intact.
   AFM-only on import (matches the metadata-extraction
   posture); 29 new tests + behavior-preserving refactor of
   `applyWithGuardrails`.
9. ~~**L-Foundation-Models Phase 2.5**~~ shipped earlier
   (commit `0e93526`) but PLANS hadn't been updated. Discovered
   on 2026-05-12 while picking it up as the follow-on after
   item 8. The implementation is complete — `PostOCRProcessor`
   protocol + `AppleFoundationModelPostProcessor` + AFM-
   fallback factory + Settings toggle all in place; only test
   coverage was missing. 9 smoke tests added to cover gating
   (vision rejection, short-text floor, clean-text threshold,
   prompt composition, protocol conformance). AFM itself isn't
   mockable; end-to-end behavior is verified by the Cloud-side
   tests since both impls share trigger gate + guardrail +
   return shape.
10. ~~**R-Metadata-Online v1 + v1.5**~~ shipped earlier
    (commits `2820d07`, `6363f30`, `d1e24b5`) but PLANS
    hadn't been updated. Discovered + corrected 2026-05-12.
    Open Library + Google Books sources, multi-source
    coordinator with concurrent fan-out and fuzzy
    duplicate-merge, picker UI with cover thumbnails,
    iCloud-syncing per-entry cover-override store.
    Still pending: v1.7 (Claude-search consolidator for
    classical / manuscript material), v2 (bulk-mode
    multi-select lookup). See R-Metadata-Online section
    for scope.
11. ~~**Q-Hard-Captures Tier 1**~~ shipped 2026-05-12
    across three commits: Q-Italic-Skip (`7db9534`),
    Q-Vision-Backfill-Batch + Q-Refused-Fallback-Surface
    (`356edf5`). **New Tier 1 sub-item added 2026-05-12**:
    Q-Code-Preservation (`<code>` + `<pre>` retention),
    elevated from hypothetical to measured-at-0%-retention
    by the corpus harness's first mini-run. ~1.5 days
    estimated.
12. ~~**T-Real-Corpus**~~ shipped 2026-05-12 as
    `humanist-cli compare-corpus <dir>`. Harness that walks
    the user's local corpus of paired PDFs + publisher
    EPUBs, converts each PDF, and reports per-book metrics
    (Jaccard word similarity, character-count ratio,
    structural deltas, inline-tag retention,
    `epub:type` alignment). Surfaces regressions in real
    conversions before tagging releases. See T-Real-Corpus
    section for the findings from the first mini-run.
13. **R-Library-Migrate — Migrate-library wizard**. Settings
    sheet that moves library.json + Embeddings/ + snapshots/
    + Covers/ + aliases.json between locations (local
    Application Support ↔ cloud-synced output root, or one
    cloud root to another). Currently `R-Library-Sync`'s
    "Share across machines" toggle only handles **first-
    time activation** (`LibrarySyncMigration.runFull` copies
    legacy SHA-keyed sidecars + aliases). There's no path
    for: turning the toggle OFF after years of cloud usage
    (leaves the existing Embeddings/ orphaned), moving the
    output root to a different folder (the catalog points
    at relative paths against the *old* root), or recovering
    from a stuck/corrupted cloud catalog. Wizard steps:
    (1) source vs. destination pickers, (2) pre-flight
    space + permission check, (3) two-phase copy (catalog
    first, then siblings) with a progress sheet that's safe
    to cancel, (4) switchover (flip the toggle + update
    `ConversionOutputResolver`), (5) post-flight verification
    (entry count, file-presence sample, re-read round-trip).
    ~1.5 days.
14. ~~**U-Splitview-Frame-Clamp — Defensive clamp of restored
    NSSplitView frames**~~ shipped 2026-05-12. New
    `SplitViewFrameClamp` helper walks every UserDefaults key
    prefixed `NSSplitView Subview Frames ` on app launch,
    parses each persisted subview-frame string (six comma-
    separated fields: `x, y, w, h, isCollapsed, isHidden`),
    and removes the whole key when any subview's width or
    height exceeds `2 × max(NSScreen.frame.{width,height})`.
    Wired into `HumanistApp.init()` before any window is built
    so AppKit's lazy autosave-read finds a clean slate.
    Screen sizes are injected, so the helper is exercised
    end-to-end without a real display. 11 unit tests cover
    the limit math, malformed strings, multi-key walks,
    non-splitview keys, empty-screen-list bail, multi-monitor
    "largest screen wins", and defensive handling of weird
    array element types. Belt-and-suspenders against the
    300-iteration `SystemSplitView` constraint loop that
    blanked the editor on 2026-05-12 (see
    `feedback_library_breaks_editor_rendering` memory for
    the original debugging path).
15. ~~**R-Library-Dedupe — Content-hash dedupe on import AND
    scan**~~ shipped 2026-05-12. All four pieces landed
    together: (1) new `ContentHash` helper streams SHA-256
    in 64 KB chunks via CryptoKit; two new fields on
    `LibraryEntry` (`sourceContentHashes: [String]`,
    `priorPaths: [String]`) with `decodeIfPresent` backward
    compat for pre-feature catalogs. (2) `EPUBImporter.
    importOne` hashes the incoming source EPUB and short-
    circuits when an existing entry already records that
    hash — appending the source path to `priorPaths` so the
    breadcrumb survives. (3) `JobRunner.runPipeline` hashes
    the incoming PDF before any OCR work and, on a hash
    match, flips the job to `.done` with a new
    `skippedReason` field (rendered as "Already in library:
    <title>" in both the launcher queue and the QueueWindow
    table, with a distinct `doc.on.doc.fill` icon to
    differentiate from a normal success). Job's `outputURL`
    is redirected to the existing entry's EPUB so Open /
    Reveal target the canonical copy. (4) New
    `truncateStemIfNeeded` in `EPUBImporter` rewrites any
    stem exceeding 200 UTF-8 bytes as
    `<truncated>~<hash8>` — deterministic, codepoint-safe,
    fits the 255-byte APFS cap with headroom for `(N).epub`
    + sync-conflict suffixes. (5) New `humanist-cli
    library-dedupe` command reads `library.json` via raw
    `JSONSerialization` (so unknown fields round-trip),
    hashes every catalog EPUB, groups identical content,
    and prints a deterministic report. With `--apply` it
    moves redundant files to Trash via
    `FileManager.trashItem`, snapshots the catalog to
    `library.dedupe-backup.json`, and rewrites the entries
    + every collection's `bookIDs`. 22 new tests across
    `ContentHashTests`, `LibraryDedupeMutatorTests`, and
    `EPUBImporterTruncateTests` cover the hash primitive
    (streamed vs in-memory, known SHA-256 vector, missing
    file, multi-chunk), the three store mutators
    (`recordSourceHash`, `addPriorPath`,
    `findEntryBySourceHash` — including legacy-catalog
    decode), and the truncation defense (boundary,
    determinism, distinct hashes for distinct overflowing
    stems, Unicode codepoint safety). CLI smoke-tested
    against a synthetic 3-entry catalog with a collection
    membership — duplicate trashed, backup written,
    catalog + collection rewritten correctly. See
    `feedback_library_breaks_editor_rendering` memory for
    how this pattern surfaced.
16. ~~**R-Library-Rescan — Re-scan source PDF with new options**~~
    shipped 2026-05-13 (commits `0b7f601`, `02b1f9a`). Library row
    context menu → "Re-scan with Current Settings…" → probe chain
    (cheap heuristics → OPF `<dc:source>` → `priorPaths`) auto-
    resolves the source PDF, or falls through to a file picker.
    Confirmation dialog names the source + target + warns about
    unsaved editor edits. Submits a job with the new
    `bypassDedupe` flag so the dedupe short-circuit doesn't fire
    against the existing entry's source-hash. JobRunner success
    path preserves the user's edited title via canonical-URL match
    in `recordConversion`. `.bak.epub` sibling copied before
    overwrite for one-click rollback. Per-rescan options sheet
    deferred — v1 uses the launcher's current settings; user
    configures options in the launcher first. Bulk re-scan for
    collection selections also deferred per original spec.
17. **P-Bilingual-FacingPage Phase (b) — parallel chapter-tree
    reorganization**. Phase (a) (detection + `data-facing-page`
    cross-link tagging) shipped 2026-05-17 with the per-book
    *Facing-page bilingual* escape hatch. Phase (b) builds on
    that to produce a Loeb-style EPUB with two parallel spines
    in one file: "Original Text" (the L1 stream as a chapter
    sequence) + "English Translation" (the L2 stream), with a
    dual-tree `nav.xhtml` and a "Jump to Facing Translation"
    editor command. Decision gate: evaluate Phase (a)'s
    detected-bilingual rate on a real Loeb corpus first. If the
    rate is sensible (low false positives, recall on facing-page
    editions the user actually owns), proceed to Phase (b);
    otherwise tighten Phase (a)'s gates and ship only Phase (a).
    ~1.5–2 days for Phase (b) once green-lit.

18. **P-Cascade-Parallel — bounded parallel pages in cascade
    mode**. Today only the Cloud page-OCR path parallelizes
    across pages; the cascade (Private mode + Cloud-cascade
    mode) processes pages serially. Wrapping the cascade
    page-loop in a bounded TaskGroup driven by the existing
    `parallelPageOCRConcurrency` knob would cut wall time
    ~2–3× on born-digital books and ~1.2–1.5× on Surya-heavy
    books in bulk Private-mode runs. 4–6 hours of careful
    refactoring across two phases — see the
    [P-Cascade-Parallel](#p-cascade-parallel--bounded-parallel-pages-in-cascade-mode)
    section below for the per-phase plan + state-change
    inventory + risk list. Earns priority when bulk
    Private-mode conversions feel slow.
19. **C-Pipeline-File-Split — carve `PDFToEPUBPipeline.swift`
    into per-concern files**. The pipeline file is 4500+ lines
    and growing — navigable via grep but hostile to first-time
    readers and to careful refactors. Split via Swift extensions
    on `PDFToEPUBPipeline` into ~7 sibling files (cascade loop,
    page-OCR dispatch, reflow, assemble, write-outputs, stats,
    engine factories), with each commit a pure move so
    correctness is diff-checkable. Pairs naturally with
    P-Cascade-Parallel (its Phase A already extracts one of the
    biggest chunks). ~1 day of mechanical work; the bulk is the
    `private → internal` access-modifier sweep. See the
    [C-Pipeline-File-Split](#c-pipeline-file-split--carve-pdftoepubpipelineswift-into-per-concern-files)
    section for the proposed split + risk list.

### Earn when you need it

10. **P10 distribution polish** (Developer ID + DMG +
    Sparkle). For tester sharing, the current ad-hoc-signed
    bundle is fine. Earns priority when "first non-tester user"
    enters the picture or when tester install friction becomes
    real.
11. **R-Library-Chat-Plus Tier 2 — pinned passages,
    ask-each-book mode**. Build if a research workflow makes
    these specifically painful.
12. **T-CI** (GitHub Actions running `swift test`). ~half day.
    Earns priority when a regression slips through that the
    test suite would have caught.
13. **P-Surya-Pool, P-Vision-Concurrency, P-Shared-Memory**.
    Performance work — earns priority when "Surya is slow" is
    the bottleneck. Today it isn't.
14. **L-Foundation-Models Phase 3** (TOC parsing). Deferred
    until AFM's 8K-token context proves workable on full TOCs
    of long books — the chunking strategy is real complexity.
15. **R-Library-Chat-Plus Tiers 3 + 4** (comparative-prompt
    presets, multiple chat threads, knowledge-graph view,
    per-book chat history surfacing, multi-model A/B). Each
    has design rationale in its tier; build only if a recurring
    real-use friction surfaces.
16. **Section-level granularity** (R-Chat-Graph-Lite's only
    remaining item). Chapter-level expansion already works;
    finer cut is opt-in only.
17. ~~**U-HIG-Pass — Mac HIG / Liquid Glass conformance**~~
    shipped 2026-05-12 across six commits: About-Credits
    (`1f87716`), Editor-Toolbar-Labels skip with rationale
    (`d1089f2`), Library `.toolbar` + `.searchable`
    (`1d13e48`), Liquid-Glass-Edges launcher background
    (`011f4d9`), A11y + keyboard-focus audit (this commit).
    Out-of-scope items still pending: Launcher-Toolbar, Help
    Book, Settings audit, full Xcode-26 Liquid-Glass inspect
    pass.

### Deferred indefinitely

These are documented for the runway and so a future picker-upper
sees the reasoning, but they're not on the build path unless the
situation that defers them changes.

- **P9 — RTL languages (Hebrew, Syriac, Coptic)**. Working
  corpus doesn't need them; bidi rendering edge cases +
  per-script Tesseract weakness aren't worth the lift.
- **Cloud Phase 8 — per-book mode override**. Obsoleted by the
  Private Mode toggle that already ships per-job override.
- **P-Greek-Quality**. Tester preference is for manuscript,
  not classical Greek. Revisit if a polytonic Greek project
  comes up; the validation methodology in the
  P-Greek-Quality section stays valid.
- **O-Telemetry**. The original plan said no telemetry; that
  posture still fits a personal / tester-shared app. Earns a
  rethink only when the user-base shape changes.
- **T-Snapshot-EPUBs, T-Memory-Regression, T-Real-Corpus**.
  Real test-coverage gaps but not load-bearing for the
  immediate work. Earn priority when a specific regression
  hits or when the user-base size makes regression-shape
  failures expensive.

When something changes that should re-shuffle this list (a tester
asks for an early-print book, the second Mac use case stops
being daily, P10 becomes urgent because someone outside the
testing circle wants the app), update this section before
anything else — the rest of PLANS.md is design rationale; this
section is decisions.

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

## P-Verse-Layout — Free-verse and irregularly-spaced poetry

**Status**: planned 2026-05-19. Pound's *Cantos*, Olson, late
Stevens, and any concrete-poetry corpus all break the
`ParagraphReflow` / `RegionAwareReflow` assumption that lines
within a region collapse into prose paragraphs. Today verse
regions emit as paragraph-shaped mush: meaningful indentation
gone, right-aligned tails left-justified, mid-line gaps closed,
multilingual italicized fragments stripped of language
attribution. This plan adds verse as a first-class layout
primitive and emits XHTML that preserves the geometry without
hard-coding `<pre>`.

### Goal

Round-trip free verse with three properties preserved:

1. **Indentation as semantics.** Each line's left margin
   (relative to the verse region's left edge) is quantized into
   ~8 buckets and emitted as `class="line indent-N"`. CSS in the
   book stylesheet maps each bucket to an `em` indent that scales
   with the reader's font size.
2. **Mid-line gaps.** Pound's signature `Clutching the greasy
   stone     "And the cloak floated"` records a gap at the
   token-index where the whitespace exceeds the line's normal
   inter-word width, emitted as `<span class="gap"></span>` with
   a width proportional to the original gap (also quantized).
3. **Right-alignment.** Lines whose `(left + text_width) ≈
   region_right` and whose `left > region_midline` get
   `class="line align-right"` — covers the `Caina attende`
   footnote-style citation pattern.

Plus correct per-fragment language tagging so screen readers
hyphenate, Greek/Italian/Latin/English mixed pages get the right
script-shaping, and the chat-with-book entity index doesn't
mis-classify a Greek noun as a misspelled English word.

### Approach

**Detection — region-level classifier.** Add `.verse` as a region
kind alongside `.text` / `.heading` / `.figure` / `.table`. Surya
labels the region as `.text` today; we promote to `.verse` based
on combined signals:

- **Ragged-right ratio**: % of lines whose right edge is more
  than 15% short of the region right margin. Prose: ~5%. Verse:
  ~70%+.
- **Line-length variance**: standard deviation of line widths.
  High for verse, low for justified prose.
- **First-token-x variance**: standard deviation of leading
  indents across consecutive lines. Near zero for prose
  (paragraphs only indent the first line); high for verse.
- **Inter-line gap variance**: prose has tight, consistent
  leading; verse often has stanza breaks.
- **End-of-line punctuation rate**: prose lines almost always
  end in a token (no trailing punctuation only matters for
  mid-paragraph wraps); verse lines frequently end without
  terminal punctuation.

AFM (or Claude Haiku in Cloud mode) classifies per region with
a yes/no verdict given those features. Cheap — one short call
per detected text region per page, batched.

**Capture — VerseRegion / VerseLine.** A new model alongside
`PageObservations`:

```swift
struct VerseRegion {
    let bbox: CGRect
    let lines: [VerseLine]
}
struct VerseLine {
    let text: String                   // raw OCR text
    let leadingIndentFraction: Double  // 0.0–1.0, relative to region width
    let intraLineGaps: [IntraLineGap]  // token-index → gap fraction
    let alignment: Alignment           // .leading / .rightAligned
    let italicSpans: [Range<String.Index>]
    let scriptSpans: [(range: Range<String.Index>, script: Script)]
}
```

Built by walking `TextObservation`s within a `.verse` region in
y-then-x order, clustering into lines by y-overlap (already
implemented in `RegionAwareReflow`), then computing per-line
geometry without collapsing into paragraphs.

**Emission — XHTML with CSS, not `<pre>`.** `<pre>` breaks reflow
on narrow screens and looks like code rather than poetry. Per
region:

```xhtml
<div class="verse" lang="en">
  <p class="line">Click of the hooves, through garbage,</p>
  <p class="line">Clutching the greasy stone<span class="gap"></span>"And the cloak floated"</p>
  <p class="line indent-3">But Varchi of Florence,</p>
  <p class="line">Then "<i lang="grc">Σίγα μαλ' αὖθις δευτέραν!</i></p>
  ...
  <p class="line align-right"><i lang="it">Caina attende</i></p>
</div>
```

Stylesheet recipe (added to `BundleAssets/book.css`):

```css
.verse { margin: 1em 0; }
.verse .line { margin: 0; text-indent: 0; }
.verse .line.indent-1 { padding-left: 1em; }
.verse .line.indent-2 { padding-left: 2em; }
...
.verse .line.align-right { text-align: right; }
.verse .gap { display: inline-block; width: 2.5em; }
```

Quantizing indents into ~8 buckets keeps the visual rhythm
without requiring `em`-level precision and survives font-size
changes in the reader.

**Per-fragment language attribution.** Verse mixes scripts more
aggressively than prose. The captured `scriptSpans` get emitted
as `<i lang="grc">` / `<i lang="it">` / `<i lang="la">` wrappers
during XHTML generation. Heuristic: Greek codepoints →
`lang="grc"`; tokens that follow `"` and contain a Romance
trigram outside our English wordlist → `lang="it"` (or `lang="la"`
when the trigram is more Latinate — confused-language tiebreaker
defers to AFM when ambiguous). The Sonnet/Gemini page-OCR path
can do this better than heuristics; new prompt addendum below.

**Sonnet/Gemini page-OCR prompt addendum.** When the page has at
least one `.verse` region, append to the existing prompt:

> When a region is poetry, emit `<div class="verse">` containing
> one `<p class="line">` per visual line. Use `class="line
> indent-N"` where N is the visual indent bucket (0–8) measured
> against the region's left margin. Use `<span class="gap"></span>`
> for mid-line whitespace gaps that look intentional. Use
> `class="line align-right"` for right-aligned lines. Preserve
> italic emphasis with `<i lang="…">` where `lang` carries the
> BCP-47 language tag (`grc` for Ancient Greek, `it` for Italian,
> `la` for Latin, etc.).

Sonnet and Gemini already do italic detection well; the addendum
mostly redirects their default `<p>`-per-paragraph instinct
toward `<p class="line">`-per-line. Estimated cost: zero — the
prompt grows by ~150 tokens which is well under the per-page
budget.

**Don't balance quotes.** Pound (and Olson and Stevens) leave
quotation marks open across many lines on purpose — it traces a
speaker through a stanza. `OCRChangeGuardrail`, smart-quote
pairing, and dictionary correction all skip `.verse` regions
entirely. The user-visible default behavior matches the printed
page.

### Known OCR-character hazards specific to verse

- **`?` misread as `>`** in serif fonts (`Se pia?` → `Se pia>`).
  Affects all serif text but verse exposes it because the
  context is shorter and grammar-checkers can't fix it.
  Cleanup pass: when `>` appears immediately before a closing
  quote or at end-of-line in a `.verse` region, promote to `?`.
- **Polytonic Greek diacritics** (`αὖθις`, `Σίγα`) — Vision
  drops them; Tesseract is uneven; Surya is better but not
  perfect. Verse OCR quality is bottlenecked by the weakest
  script engine on the page. Sonnet/Gemini OCR is the strongest
  path here when Cloud mode is on.
- **Italian elisions inside words** (`μαλ'` = `μάλα` with
  elision) — apostrophe-inside-token can confuse line-splitters
  that treat `'` as a clause boundary. Verse capture must
  preserve the apostrophe as a regular character.

### Effort estimate

- **v1 narrow** — detect + classify + indent-bucketed emission +
  per-line language tagging, no intra-line gaps, no
  right-alignment: ~1 day.
- **v2 full** — adds intra-line gaps, right-alignment detection,
  Sonnet/Gemini prompt addendum, dedicated `.verse` post-OCR
  cleanup rules: ~3–4 additional days.
- **Corpus-side**: a handful of Pound / Olson / Stevens pages
  added to the `compare-corpus` harness so regressions on
  free-verse layout get caught. ~0.5 day.

### Dependencies

- Surya layout (already shipped) for `.text` region detection
  that we promote to `.verse`.
- AFM classifier path (already shipped) for the verse-vs-prose
  per-region call.
- Cloud Page OCR (already shipped) for the prompt-addendum
  variant — strongest quality bar when Cloud mode is on.
- Custom book CSS (R-Custom-Styles, shipped) for the
  per-book stylesheet additions.

### Out of scope (deferred)

- **Concrete poetry / typewriter visual poetry** (e.g. Hollander,
  bp Nichol). Requires exact-coordinate preservation, custom
  glyph shapes, sometimes color. `<pre>` with `font-variant:
  tabular-nums` would handle a subset; the full thing needs SVG
  emission and is a Tier 8 stretch item.
- **Verse drama with speaker labels** (Shakespeare, Beckett).
  Heuristic: speaker labels are short, all-caps or italic, end
  in punctuation, on their own line. Worth a separate
  `.verse-drama` sub-classifier when a corpus demands it.
- **Numbered/lined verse** (Whitman, classical epics). Line
  numbers in the gutter map cleanly to `<p class="line"
  data-line-number="N">` but only matter for a specialist
  audience.

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
| Hard-region OCR (Cloud cascade Stage 2.5) | Google Cloud Vision `DOCUMENT_TEXT_DETECTION` | Classical OCR at ~$0.0015/call; absorbs most of the hard-region tail before falling through to Claude |
| Hard-region OCR (Cloud cascade tail) | Sonnet 4.6 | Trusted as ground truth; multilingual + ancient scripts demand the strongest visual reasoning |
| Page OCR (whole-page → XHTML) | User-selectable: Sonnet 4.6 (default; best on dense academic layouts), Gemini 2.5 Flash (~7–10× cheaper; GA), or Gemini 3 Flash preview (newer reasoning model; `thinking_level: minimal` pinned) | Manuscript mode hard-pins Opus regardless of pick. See P-Page-Provider-Choice in the shipped log. |
| Manuscript-mode page OCR | Opus 4.7 | Handwriting recognition; Sonnet drops detail on secretary / round hand; Gemini Flash family hasn't been validated on diplomatic-transcription prompts |
| Table extraction (replacing Path A) | Sonnet 4.6 | Spatial reasoning + structure understanding; tables are rare per book so cost is bounded |
| Post-OCR character cleanup | Haiku 4.5 | Targeted edits (ligatures, diacritics, long-s); no need for Sonnet |
| Semantic chapter classification | Haiku 4.5 | Tiny prompt, closed label set, ~per-chapter |
| TOC parsing | Haiku 4.5 (Sonnet escalation if quality bad) | One call per book, ~$0.001 either way |

Mental model: **classical OCR (Document AI) at the cascade's
cheap tier, Haiku for "polish / classify text we already have,"
Sonnet or Gemini Flash for "look at this image and produce
ground-truth content."**

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
| Page-OCR-Multi | User-selectable page-OCR provider (Sonnet / Gemini 2.5 Flash / Gemini 3 Flash preview); per-provider key store | **Done** (commits `e11722c`, `8625ed4`) |
| Cascade 2.5 | Google Cloud Vision `DOCUMENT_TEXT_DETECTION` slotted between Tesseract and Claude in `RegionCascade` | **Done** (commit `e11722c`) |
| Refusal-Rate | Per-page `ProviderStatus` classification (refused / empty / apiError); surfaced in `ConversionStats`, summary string, `claude-pages.txt` header, queue tooltip | **Done** (commit `a5dd6dc`) |
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

## R-Split-Filename-Sanity — Bound chapter-split filename growth

**Status**: shipped 2026-05-12 (this commit). Two defenses in
`EPUBBook.nextAvailableHref(near:)`:

1. **Suffix-stripping**: a new `stripSplitSuffix(from:)` helper
   strips trailing `_split_NNN` segments (any digit count,
   iterative for already-pathological stems). Splitting
   `chapter-001_split_001` now produces
   `chapter-001_split_002` (sibling), not
   `chapter-001_split_001_split_001` (descendant).
2. **Byte cap**: candidate href is checked against a 200-byte
   UTF-8 ceiling. When the iterating counter would push it
   past, fall back to `chapter-NNN.{ext}` minted via a private
   `fallbackCounterHref(...)` helper — same collision semantics
   as the primary path, just a different stem.

The 200-byte cap leaves ~50 bytes of headroom under macOS
APFS's 255-byte limit for OS-prefix paths. Counter ceiling at
999 splits is a defensive belt-and-suspenders cap on the
primary loop too.

11 new `NextAvailableHrefTests` cover the suffix-stripper's
boundary cases (no suffix, single, 23-deep stack from the
Benjamin EPUB, varied counter widths, mid-string non-matching
patterns), the sibling-counter behavior on re-split, a 30-
successive-splits stress that asserts the bound holds, and
the byte-cap fallback with and without `chapter-NNN`
collisions. 1070 tests pass total.

### Root cause (preserved for archaeology)

[`EPUBBook.nextAvailableHref(near:)`]
(Sources/EPUB/EPUBBook.swift) used to take the source chapter's
*full* current stem and append `_split_NNN`. So:

- split `chapter-001.xhtml` → second piece = `chapter-001_split_001.xhtml`
- split THAT → `chapter-001_split_001_split_001.xhtml`
- split THAT → `chapter-001_split_001_split_001_split_001.xhtml`
- …

Each split added 10 chars to the stem. After 23 splits the
href was 245 bytes (≈ `text/` + 232-char stem + `.xhtml`).
macOS APFS truncated at 255 bytes, clipping the trailing `ml`
from the extension. The manifest still recorded the intended
`.xhtml`, the disk file became `.xht`, and the EPUB silently
broke. Now fixed.

### Content-aware rename (separate, related)

The user also asked for "a content-aware rename feature" —
see R-Content-Aware-Rename below. Bounding the auto-name
growth was the minimum fix; the content-aware rename is the
better default. Sanity bound shipped first as defense-in-
depth so the next person to import a Sigil-edited EPUB with
existing growth can't trip the breakage either.

---

## R-Content-Aware-Rename — Rename chapters from their content

**Status**: complete. Manual rename shipped 2026-05-13
(commit `3d8d88b`); auto-name-on-split shipped 2026-05-18.

1. ~~**Auto-name on split.**~~ Shipped 2026-05-18. New
   `EPUBBook.nextAvailableHref(slug:near:)` mints
   `<dir>/<slug>.<ext>` (with `-2`, `-3`, … collision suffixes)
   inheriting the source's dir + ext, with the same byte cap +
   counter ceiling defenses as the `_split_NNN` counter path.
   Returns nil on empty slug or byte-cap overrun, signaling the
   caller to fall back. `BookPackageEditor.splitChapter` now
   tries the slug path first — extracts the second half's first
   `<h1>` / `<h2>` / `<h3>` via `PackageEditor.firstHeadingTitle`,
   slugifies via the existing `Slug.fromHeading`, mints the
   slug-derived href when available, falls back to the counter
   scheme otherwise. 6 new tests across `NextAvailableHrefTests`
   (slug pattern, dir/ext inheritance, collision-suffix,
   empty-slug nil, byte-cap nil) and `BookPackageEditorTests`
   (end-to-end split with embedded `<h2>` yields slug href;
   bodies without headings still fall through to counter
   scheme).
2. ~~**Manual rename to match content.**~~ Shipped 2026-05-13
   (commit `3d8d88b`). New `EPUB.Slug.fromHeading` helper +
   `EditorViewModel.beginRenameChapterFromFirstHeading(at:)` +
   "Rename Chapter from First Heading…" entry in BookBrowser's
   chapter context menu. Reads the chapter's first heading from
   the in-memory buffer (catching unsaved edits) or disk,
   slugifies it (decode entities → strip tags → whitespace to
   hyphens → whitelist filter to `[A-Za-z0-9._-]` → collapse
   consecutive hyphens → trim → cap at 80 chars on a hyphen
   boundary), and opens the existing rename prompt pre-filled
   with the slug. User can still edit before commit; internal-
   link rewriting + file-tree refresh reuse the standard
   rename path. 19 SlugTests cover the spec; menu grays out
   when no usable heading exists.

### Slug rules

- Take first heading text (`<h1>` preferred, then `<h2>`,
  then `<h3>`); empty heading → fall back to counter scheme.
- Strip XML entities + decode HTML; collapse runs of
  whitespace.
- Replace internal whitespace with hyphens (or keep spaces
  — both are valid in EPUB hrefs and spaces preserve the
  human-readable form the user might prefer).
- Strip / replace characters that break filesystems: `/`,
  `\`, `:`, `*`, `?`, `"`, `<`, `>`, `|`. (Apostrophes are
  fine in macOS / EPUB but get URL-encoded.)
- Cap at 80 chars before extension. Truncate at the nearest
  word boundary so the title remains readable.
- Collision-check: if `<slug>.xhtml` exists, append ` -2`,
  ` -3`, etc. Same iteration as `nextAvailableResourceID`.

### Integration with existing chapter rename

The editor already has a chapter rename surface
(`pendingRename` state + alert sheet in `EditorView.swift`).
The new "auto-rename to match content" command can:
- Read the chapter's current first heading via
  `BookPackageEditor.previewHeading(for:)` (or similar new
  helper).
- Stage the resulting slug as `pendingRename.newBaseName`.
- Reuse the existing apply path (which already rewrites
  internal links via the rename machinery).

### Effort

- R-Split-Filename-Sanity (defense): ~½ day.
- R-Content-Aware-Rename auto-on-split: ~1 day (slug helper +
  wire into `splitChapter` + tests).
- R-Content-Aware-Rename manual command: ~½ day (menu item +
  default-from-heading + existing rename path).

Total: ~2 days for both together. Sanity bound is the
must-have; content-aware is the nice-to-have that makes the
sanity bound rarely triggered.

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

## R-Reader — EPUB viewer mode with chat sidebar

**Status**: planned 2026-05-18. Adds a distraction-light reading
surface alongside the existing Editor so Humanist works as a reader,
not just a library + converter. Reader becomes the default action
for an `.epub`; editing becomes an explicit jump.

### Decisions locked

- **Layout**: ship scrolling first, paginated columns as a follow-up
  phase. User-selectable in Settings.
- **Default open**: opening an `.epub` (Library double-click, File →
  Open, drag-drop) routes to Reader. Explicit "Edit Source…" action
  opens the existing Editor scene on the same URL.
- **Chat scope**: current-book only — no library scope picker, no
  exclusion list, no federated-index status. Library-scope chat
  stays in the Library window where it already lives.
- **Resume position**: in scope for v1. Persisted per content hash so
  non-library opens resume too.

### Architecture

One new scene, ~five new SwiftUI files, one new sidecar store.
Everything else is reuse.

- `WindowGroup("Reader", id: "reader", for: URL.self)` in
  `HumanistApp` — sibling of the Editor scene, same per-URL
  window-reuse semantics.
- `ReaderView` (root) → 3-column `NavigationSplitView`: **TOC
  sidebar** | **Reading pane** | **Chat sidebar** (chat collapsible,
  on by default).
- `ReaderViewModel` (`@MainActor ObservableObject`) — owns the
  `EPUBBook`, current spine index, layout mode, theme/font prefs,
  and the lifecycle of the embedded `BookChatViewModel`.
- `ReadingPositionStore` — Application-Support sidecar keyed by
  EPUB content hash; survives Library purges and lets non-library
  opens resume too.

### Reuse vs new

| Concern | Reuse | New |
|---|---|---|
| EPUB load + spine + nav | `EPUBBook.open(epubURL:)`, `Resource.text`, `book.spine` | — |
| Chapter rendering (scroll mode) | `WebPreviewPane` from `Editor/PreviewView.swift` — extract the WKWebView wrapper so reader and editor both consume it | thin wrapper that loads spine items one at a time |
| Chapter rendering (paginated) | Same WKWebView host | `ReaderPaginator.swift` JS-bridge: applies `column-width: 100vw; height: 100vh`, measures `scrollWidth`, exposes `goToPage(n)` / `pageCount` / `currentPage` |
| TOC sidebar | `ChapterHierarchy` / `ParsedTOC` parsing already used by the editor | `ReaderTOCSidebar` — pure presentation; click jumps spine + scroll |
| Chat | `BookChatViewModel` + `ChatPaneView` retrieval + citation chips + Anthropic plumbing unchanged | locked-scope `ReaderChatPaneView` wrapper (~80 LOC) — hides scope strip, exclusion row, federated-index status |
| Window infra | `humanistChrome`, `WindowSwitcher` | extend `OpenRouter.open` to route epub → reader; add `Window > Show Reader` (⌘5) |

### Chat sidebar — current-book only

`BookChatViewModel.chatScope` is constructed locked to
`.currentBook`. `ReaderChatPaneView` renders transcript + indexing
banner + fallback strip + input row only. Citation chips snap the
reading pane to the cited chapter (spine index + scroll-to-anchor)
— mirrors the editor's "click chip → jump to chapter" behavior.

### Reading position model

```swift
struct ReadingPosition: Codable {
    let contentHash: String      // ContentHash.compute(epubURL)
    var spineIndex: Int          // 0-based
    var scrollFraction: Double   // 0.0–1.0, scroll mode
    var pageIndex: Int?          // paginated mode override
    var layoutKind: ReaderLayoutKind  // .scroll | .paginated
    var updatedAt: Date
}
```

Stored at `Application Support/Humanist/ReadingPositions/
<contentHash>.json`. Writes debounced to ~500ms after the user
stops scrolling/paging. Library window picks these up in a later
phase and shows a "Continue reading" affordance.

### Commits / phasing

Each commit shippable on its own.

**Phase 1 — Reader scene with scroll layout (no chat yet)**

1. **R-Reader-Scene-Skeleton** — Add `ReaderView` + `ReaderViewModel`.
   Three-column `NavigationSplitView`: stub TOC, single-column
   scrolling chapter view via WKWebView (extracted from
   `PreviewView`), no chat. New `WindowGroup("Reader", id: "reader",
   for: URL.self)` in `HumanistApp.swift`. Toolbar: prev/next chapter,
   font-size stepper.
2. **R-Reader-Default-Open** — `OpenRouter.open(_:openWindow:)`
   routes `.epub` → reader instead of editor. Add `File > Edit
   Source…` (⌥⌘O) and a Reader toolbar button that opens the existing
   Editor scene on the same URL. Add `Window > Show Reader` (⌘5 —
   verify unreserved).
3. **R-Reader-TOC-Sidebar** — Parse `nav.xhtml` via
   `ChapterHierarchy`; clickable rows navigate the spine. Persist
   sidebar collapsed/expanded state via `@AppStorage`.
4. **R-Reader-Position-Persistence** — `ReadingPositionStore` +
   debounced writes + restore-on-open. Library row hover affordance
   deferred to a follow-up.

**Phase 2 — Chat sidebar**

5. **R-Reader-Chat-Pane** — `ReaderChatPaneView` (stripped-down
   `ChatPaneView`), `ReaderViewModel.ensureChatViewModel()`
   mirroring `EditorViewModel.ensureChatViewModel`. View menu toggle
   + ⌥⌘C shortcut consistent with the editor. Citation chips snap
   the reading pane to the cited chapter.

**Phase 3 — Paginated layout**

6. **R-Reader-Pagination** — `ReaderPaginator.swift` JS-bridge.
   Settings → Reader pane: layout toggle (Scroll / Paginated), theme
   (System / Sepia / Dark), font family + size. ←/→/space page
   navigation; trackpad swipe via `NSEvent.swipeWithEvent` if cheap.

**Phase 4 — Polish**

7. **R-Reader-Reading-Prefs** — Font face picker (system reading
   fonts), line-spacing, margin width. Reuse editor preview's theme
   injection pattern (`<style>` overrides at chapter load).
8. **R-Reader-Library-Continue** — Library window "Continue reading"
   hover badge + double-click respects last position.

### Edit-Reader interaction

Reader and Editor both load the same `.epub` from disk independently
into their own `EPUBBook`. If the user saves in the Editor while the
Reader is open, the Reader's in-memory book is stale. Plan: post a
notification on `EditorViewModel.save()` completion; Reader observes
and shows an inline "Book changed on disk — Reload" banner. Never
auto-reload (would lose the user's place mid-paragraph).

### Open sub-questions to confirm before Phase 1

- ⌘5 is the natural next slot after Queue (⌘4). Unreserved per
  MACUX checklist, but verify against any Show-* shortcuts added
  since.
- Recents: Reader opens still call `RecentsStore.add(url)` —
  handled by extending `OpenRouter.open` rather than per-scene
  bookkeeping.

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

**Status**: complete. Every item in the original backlog
shipped. Kept here as a record of the punch-list and where each
piece landed so the design intent isn't lost to git history.

### Backlog

- ~~**Bulk-index command**~~ shipped (commit `fc33b0d`).
  `LibraryIndexBuilder` walks every cataloged EPUB and builds /
  refreshes its embedding + hierarchy + entity sidecar against
  the user's chosen backend; skips books already current; force-
  rebuild option wipes and re-runs. Triggered from the Library
  window's circular-arrow menu ("Build Missing Indexes" /
  "Rebuild All Indexes"); progress sheet shows per-book progress
  + failure list.
- ~~**Per-book "Rebuild index" button"**~~ shipped. Circular-arrow
  button in the per-book chat pane header (`Editor → Chat`) calls
  `BookChatViewModel.rebuildIndex()` which wipes the book's
  sidecar and re-runs the embedding + hierarchy + entity passes.
  Library chat pane has the same affordance for the federated
  index (`LibraryChatViewModel.invalidateLibraryIndex()` triggers
  a fresh sidecar walk on the next message).
- ~~**Backend-fallback visibility**~~ shipped. `BookChatViewModel`
  and `LibraryChatViewModel` both publish `fallbackNote`; per-book
  and library chat panes render an inline orange notice strip when
  set so silent backend degrades (Voyage key rotated, Ollama daemon
  stopped, etc.) actually surface to the user.
- ~~**Backend-swap cascade**~~ shipped. Settings posts
  `humanistEmbeddingBackendChanged` whenever the backend choice or
  any per-backend model field changes; both `BookChatViewModel`
  and `LibraryChatViewModel` observe and drop their cached indexes
  so the next send re-resolves with the new backend.
- ~~**Paragraph-level citation jumps**~~ shipped. Render context
  now emits `[chapter:N para:M]` markers per paragraph (per-book)
  and `[book:N chapter:M para:K]` (library); system prompts updated
  to teach the model the new form. `BookChatCitation.paragraphIndex`
  carries the parsed value; chips show "ch. N ¶ M" when set;
  per-book citations route through a new
  `EditorViewModel.requestParagraphScroll(resourceID:paragraphIdx:)`
  that selects the chapter (if needed) and posts an
  `AnchorScrollRequest` for `<p id="hu-p-N-M">` so source +
  preview both land on the cited paragraph. Library citations
  carry the paragraph index for chip labeling but still open in
  a new window — passing the anchor through `OpenRouter.open`
  would require window-state plumbing that's out of scope for
  this round.
- ~~**Retrieval debug surface**~~ shipped. `RetrievalDetail` is a
  new optional field on `BookChatMessage` (decodeIfPresent for
  backward compat); both VMs capture per-hit score + rank +
  hierarchy / entity flags at send time. Chat panes have an
  `info.circle` toggle in the chrome that flips a per-window
  state; when on, each assistant message renders a monospaced
  hit summary beneath its citation strip ("ch.3 ¶7
  score=0.045 bm25=2 emb=1 ent✓").
- ~~**Tunable knobs in Settings**~~ shipped. Advanced retrieval
  disclosure in Settings → AI → Chat Retrieval with three
  stepper rows for RRF k (default 60), Top-K paragraphs
  (default 12), and Max paragraph chars (default 4000). 0 in
  the persisted value means "use default", so the Reset button
  zeroes the binding rather than seeding a hardcoded number.
  `HybridRetriever.rrfK` is now an instance property;
  `LibraryEmbeddingIndex.search` takes `rrfK` as a parameter.
  Both chat VMs read the persisted values per-send so changes
  apply immediately.
- ~~**Window-switcher menu commands**~~ shipped. `Window > Show
  Converter` (`⌘1`) / `Show Library` (`⌘2`) / `Show Editor`
  (`⌘3`) / `Show Queue` (`⌘4`). Single-instance scenes use
  `openWindow(id:)`; multi-instance scenes (Converter, Editor)
  go through `WindowSwitcher` which finds the most-recent window
  in `NSApp.windows` and brings it forward rather than spawning
  a new instance every chord press.

### When to ship

Anytime; pick whichever items are biting hardest. None of them
require new infrastructure.

---

## R-Library-Chat — First-class library window with embedded chat

**Status**: shipped. The library window now has a collapsible chat
pane on the right (toggled via `⌘/` or the bubble button in the
filter bar) backed by a dedicated `LibraryChatViewModel`. Window-
switcher menu commands wired alongside (`⌘1` Show Converter,
`⌘2` Show Library, `⌘3` Show Editor, `⌘4` Show Queue).

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

## R-Library-Chat-Plus — Workflow enhancements for the library chat surface

**Status**: Tier 1 complete (Chat with Selected, Collections,
Suggested follow-ups, Long-form synthesis, Per-book exclusion).
Tiers 2–4 not started. The library window now has a chat pane
(R-Library-Chat) and the federation works end-to-end. This entry
is the backlog of enhancements that level it up from "ask
questions across my library" to "use this as the primary research
surface." Items are independently shippable in 30 minutes to 1-2
days; the order below is the recommended priority for actual
research workflow value.

### Tier 1 — clear wins, build first

These are short, obvious, and unlock follow-on value. The first
two as a pair are the highest-leverage thing on this entire list.

1. ~~**Chat with Selected**~~ shipped. Library window's filter bar
   gains a "Chat with Selected (n)" button when rows are selected;
   click scopes the library chat to those rows and reveals the
   pane. `LibraryChatViewModel.scopedURLs` drives the retrieval
   filter; `LibraryEmbeddingIndex.search` gained a `restrictTo`
   parameter; status row shows "Scoped to: book1, book2, …" with
   a Clear button.
2. ~~**Collections**~~ shipped. Durable named groupings persisted
   on `LibraryStore` as a `BookCollection` array (file format grew
   a wrapper; legacy bare-array reads still work). Library window
   gained a toggleable left sidebar listing "All Books" + each
   collection; clicking a collection filters the table to its
   members in stored membership order. Row context menu offers
   "Add to Collection ▸" with existing collections + a
   "New Collection…" entry that seeds membership from the current
   selection. Filter bar swaps the "Chat with Selected" button
   for "Chat with {Collection} (N)" when a collection is the
   active filter and nothing is selected. Sidebar context menu:
   "Chat with This Collection", "Rename…", "Delete".
3. ~~**Suggested follow-ups**~~ shipped. Model emits 2-3 questions
   inside a `[follow-ups]…[/follow-ups]` block at the end of each
   response; `FollowUpParser` strips the block from the visible
   text and exposes the list as one-click buttons under the
   citation strip. Click sends as next user turn (gated on
   `isThinking` to avoid streamTask races).
4. ~~**Long-form synthesis toggle**~~ shipped. Per-window flag on
   both VMs flips the system prompt's length-guidance addendum and
   lifts `maxTokens` from 1500 → 4000. Toggle button in the chat
   pane chrome (`doc.text` icon).
5. ~~**Per-book exclusion**~~ shipped. Citation chip's right-click
   context menu offers "Exclude {Book Title} from chat"; the
   excluded set is a session-scoped deny-list applied via a new
   `excluding` parameter on `LibraryEmbeddingIndex.search`. Status
   banner with "Excluded N books · Clear" when active. Works in
   both library chat (LibraryChatViewModel) and per-book chat's
   library scope (BookChatViewModel.excludedLibraryBookURLs).

### Tier 2 — research-workflow utility

These shape the chat output for downstream use (research notes,
citations, drafting). Not as universally useful as Tier 1; pick
based on whether your workflow leans heavily on writing-up.

6. ~~**Citation export**~~ shipped (commit `6c63714`).
   `ChatCitationFormatter` turns `[book:N chapter:M]` markers
   into Chicago note-style strings — `Author, *Title*, "Chapter
   Title", ¶ N.` — with graceful fallbacks when fields are
   missing (no author → title-only; no chapter title → "ch. N";
   no catalog entry → citation's own `bookTitle`). Three entry
   points: `format` (one), `bibliography` (numbered Markdown
   list with dedup), `transcript` (full Markdown research note
   with inline footnote markers + Sources section). Year /
   publisher / ISBN aren't surfaced through `LibraryEntry`
   today; formatter handles their absence and future enrichment
   slots in without changing the API.
7. ~~**Conversation export**~~ shipped (commit `6c63714`).
   `ChatPaneView` and `LibraryChatPaneView` gained "Export
   Transcript…" actions that write Markdown via
   `ChatCitationFormatter.transcript`. Citations resolve through
   `LibraryStore.entries` to per-book metadata at export time.
   8 new `ChatCitationFormatterTests` cover the format-string
   matrix, bibliography dedup + numbering, and transcript shape.
8. **Pinned passages** — when chat surfaces a passage worth
   keeping, click a star on the citation to save it to a per-
   library "Quotes" pane (passage text + source book + chapter +
   the question that surfaced it). Becomes a chat-driven
   highlights file. ~1 day. Pairs naturally with Citation export.
9. **Ask-each-book mode** — one query, one independent answer
   *per book in scope*. Different from today's RRF-merged answer;
   useful for surveys ("what does each of these books say about
   X?") rather than synthesis ("what does my library say about
   X?"). Surface as a toggle in the scope strip. ~3-4 hours.

### Tier 3 — nice-to-haves; build only if motivated

Genuinely useful but neither universally needed nor cheap. Skip
unless one matches an actual recurring pain point.

10. **Comparative-prompt presets** — saved system prompts the
    user picks per session ("primary-source quotation finder",
    "careful historian", "argumentative summary", "translation
    comparison"). Library of canned scholarly stances. ~half day.
    Worth building only if the user finds themselves rewriting
    the same prompt prefix repeatedly.
11. **Multiple chat threads** — named threads ("Power chapter
    research", "translation comparison") rather than one rolling
    transcript. ~1 day. Likely overkill for solo use; useful when
    the user is juggling several research projects in parallel.
12. **Retrieval debug surface** — already in `R-Chat-Polish`.
    Hit `bm25Rank` / `embeddingRank` / `hierarchyMatched` /
    `entityMatched` are already on `HybridRetriever.Hit`; just
    needs a UI toggle. Critical when retrieval misfires and the
    user wants to know whether to fix the query, the alias
    dictionary, or the backend choice. ~1-2 hours.

### Tier 4 — speculative

Real engineering investment, uncertain payoff. Document for the
runway; don't build unless a specific need surfaces.

13. **Knowledge-graph view** — interactive graph of the
    federated `LibraryEntityIndex`: people / places / concepts as
    nodes, co-occurrence as edges. Click a node to seed a chat
    about that entity. The data is already extracted; the new
    work is the layout / interaction (D3-ish in WebView, or a
    native SwiftUI graph). ~3-5 days. Visually impressive but
    most actual research happens through targeted chat queries,
    not graph browsing. Build if the user finds themselves
    asking "what's near X in my library?" frequently.
14. **Per-book chat history surfacing** — when reading a book in
    the editor, the chat pane shows "asked about this book in
    library chat: 7 times" with one-click recall. Cross-context
    recall. ~half day. Speculative value — depends on whether
    the user actually re-reads questions they already asked.
15. **Multi-model A/B in library scope** — same query through
    Sonnet and Gemini (or any two backends) side-by-side. Useful
    when the user doesn't trust one model's reading on a hard
    question. ~1 day. Doubles per-query cost; skip unless model
    disagreement is biting.

### Caveats

- **Don't build the speculative items first** even if they sound
  exciting. The Tier 1 scope-control items multiply the value of
  every other item below them — chat-with-selected makes
  ask-each-book actually useful, citation export is more
  meaningful when you can scope the conversation that produced
  the citations, etc. Build the foundation before the visualization.
- **Citation export depends on book metadata**. Books converted
  before the metadata-extraction Cloud feature shipped won't have
  authors / publishers / years populated. The exporter should
  fall back to the source filename + chapter title with a "(no
  author / year recorded)" note rather than fabricating.
- **Multiple chat threads conflict with how the transcript is
  persisted today**. The library transcript is a single
  `library.json` keyed by app instance; threading would require
  rethinking the schema. If we do it, do it before pinned
  passages so the pin storage can reference a thread id.
- **Knowledge-graph view is the easiest item to over-engineer**.
  Force-directed-layout-with-zoom-pan-tooltips is days of
  fiddly UI; the question to answer first is whether the
  *feature* is valuable, not whether it can be polished.

### Sequencing

Recommended order if you build any of this:

1. Chat with Selected (1-2 hours) — instant payoff.
2. Suggested follow-ups (2 hours) — instant payoff, orthogonal.
3. Long-form synthesis toggle (30 min) — instant payoff.
4. Per-book exclusion (1-2 hours).
5. Collections (1-2 days) — durable groupings; unlocks
   recurring-scope workflows.
6. Citation export (4-6 hours).
7. Conversation export (2-3 hours).
8. Pinned passages (1 day) — pairs with the export items.
9. Ask-each-book mode (3-4 hours).
10. Comparative-prompt presets (half day) if needed.
11. Retrieval debug surface (1-2 hours) — moved up if retrieval
    is misfiring.
12. Multi-model A/B (1 day) if model disagreement bites.
13. Multiple chat threads (1 day) if juggling projects.
14. Knowledge-graph view (3-5 days) — last; speculative.

The first four items combined are about 5 hours of work and
deliver most of the research-workflow value. Tier 2 adds 2-3
days for the writing-up flow. Tier 3 + 4 are opt-in based on
real friction.

### Dependencies

- `R-Chat-Graph-Lite` (shipped) for the federated index that
  every item here builds on.
- `R-Library-Chat` (shipped) for the surface.
- `LibraryStore` for collections persistence; existing JSON
  format gains a `collections: [Collection]` field.
- Citation export consumes `book.metadata` populated by the
  metadata-extraction Cloud feature; documented fallback
  for books without it.

---

## R-EPUB-Import — Bring existing EPUBs into the library

**Status**: v1 shipped. File → Import EPUB into Library… (⇧⌘I)
and a Library-window button open an `NSOpenPanel` multi-select on
`.epub`; the picked sources run through `EPUBImporter` which opens
each book via `EPUBBook.open`, injects paragraph anchors via
`ParagraphAnchorInjector`, flushes through `EPUBBookSaver`,
repacks via `EPUBRepacker` to the configured Books folder (or
`~/Documents/Humanist Library/Books/` when no output root is
configured), catalogs in `LibraryStore.recordConversion`, and
builds the embedding sidecar via the new `BookSidecarBuilder`
shared with `LibraryIndexBuilder`. Re-import is idempotent
(paragraph anchors skipped when present; catalog row updates in
place via canonical-URL match). 13 new
`ParagraphAnchorInjectorTests` cover the rewriter end to end.

### What landed in v1

- **`ParagraphAnchorInjector`** (Sources/Pipeline) — regex
  walker over `<p>` opening tags; injects
  `id="hu-p-{chapter}-{para}"` only where `id=` is absent.
  Word-boundary anchor rejects `<pre>` / `<picture>`; tolerant
  of single- and double-quoted attributes, whitespace around
  `=`, mixed case (`<P>` / `<p ID="...">`). Per-chapter counter
  increments on every `<p>` so injections sit at their true
  document-order ordinal.
- **`EPUBImporter`** (Sources/Humanist/Library) — main-actor
  `ObservableObject` that publishes per-book progress + a
  failures array; runs the open → inject → save → repack →
  catalog → index pipeline serially. Backend resolution is
  best-effort: imports proceed even when no embedding backend
  is available (catalog gets the row; chat just can't retrieve
  from it until a separate index pass runs).
- **`BookSidecarBuilder`** — pulled out of
  `LibraryIndexBuilder.buildOneBook` so both the bulk indexer
  and the importer build the same shape without duplicating
  cache / backend / EPUB-open machinery.
- **`ImportEPUBProgressSheet`** (Sources/Humanist/Library) —
  same shape as `LibraryIndexProgressSheet`: header status,
  progress bar, "N of M", failures disclosure.
- **File menu**: "Import EPUB into Library…" with `⇧⌘I`.
  Opens the Library window first, then posts
  `humanistImportEPUBRequested` for the window to handle.
- **Library window**: `tray.and.arrow.down` button next to the
  bulk-index menu in the filter bar.

### What landed in v1.3

- **Year / publisher / ISBN round-trip**. `OPFReader.Metadata`
  gained three new fields; the reader extracts a 4-digit year
  prefix from `<dc:date>` (tolerating ISO-timestamp shapes),
  the publisher from `<dc:publisher>`, and the ISBN from any
  `<dc:identifier>` that's URN-shaped (`urn:isbn:…`) or
  carries an explicit `scheme="ISBN"` / `opf:scheme="ISBN"`
  attribute. The package's `unique-identifier` element is
  excluded — it's identity, not bibliographic ISBN, even when
  ISBN-shaped.
- **`upsertISBNIdentifier`** in `EPUBBookSaver`. Writes the
  ISBN as a *new* `<dc:identifier>urn:isbn:VALUE</dc:identifier>`
  sibling next to the existing identifiers (matches the
  conversion path's `OPFWriter` output shape). When a
  URN-shaped Humanist-emitted ISBN already exists, updates it
  in place. The package's unique-identifier is never a
  candidate so it survives every save.
- **`EPUBImporter.applyMetadata`** now passes all five
  extracted fields through — title + author + year +
  publisher + ISBN.
- **11 new `OPFMetadataExtendedTests`** cover the parse
  shapes (bare year, ISO timestamp, URN ISBN, scheme-attr
  ISBN, hyphen stripping), the read-side skip-package-unique-id
  invariant, and the save-side round-trip (year + publisher
  back, ISBN as separate identifier, in-place update on
  re-save, unique-identifier preserved).

### What landed in v1.2

- **AFM chapter classification on import** via the
  cheap-shortcut path described in v1's deferral notes.
  `EPUBImporter.buildMinimalChapter(from:)` extracts title
  (first `<h1>` content, falling back to `<title>`) and ~800
  chars of opening text from `<p>` / `<h2>`–`<h6>` /
  `<blockquote>` / `<li>` elements (figures / tables / anchors
  / footnotes excluded — they carry no classifier signal).
  Per-resource classification happens between metadata
  extraction and the save step.
- **`BodyTypeInjector`** (Sources/Pipeline) — regex rewriter
  that finds `<body...>` opening tags and inserts `epub:type`
  preserving any existing attributes + the original tag casing.
  Conservative: an existing `epub:type` on `<body>` is left in
  place (a publisher's deliberate "afterword" beats the
  classifier's "appendix" guess). Emits an `xmlns:epub`
  declaration inline when the doc lacks one anywhere, so the
  rewritten XHTML stays spec-valid.
- **26 new tests** across `BodyTypeInjectorTests` (case
  preservation, attribute preservation, namespace handling,
  preserve-existing-label posture, the whitespace-around-`=`
  edge case) and `EPUBImporterSamplerTests`
  (`extractFirstTitle` / `extractOpeningText` /
  `buildMinimalChapter`).

### What landed in the v1.1 follow-up

- **Folder + drag-drop import**: `EPUBImporter.expandSources(_:)`
  walks any directory in the picked list recursively for `.epub`
  files (sorted by path so the import order is deterministic;
  hidden + package-internal children skipped). The File →
  Import EPUBs into Library… picker now allows directory
  selection alongside files (`canChooseDirectories = true` with
  the `.epub` type filter still applied to file rows). The
  Library window gains `.dropDestination(for: URL.self)` —
  drop a `.epub`, a folder of EPUBs, or any mix; everything
  flattens through `expandSources` before reaching
  `EPUBImporter.start`.
- **AFM metadata extraction on import**: when the on-device
  toggle (`AISettings.localFeatures.localMetadataExtraction`)
  is on and Apple Intelligence is available, the importer
  samples the first ~4 KB of stripped front-matter from the
  first two spine resources and runs
  `AppleFoundationModelMetadataExtractor`. Extracted title +
  author write back into `book.metadata`, which round-trips
  through `EPUBBookSaver.updateMetadataInPlace` so the OPF
  gets the new `<dc:title>` / `<dc:creator>` values. The
  library catalog row picks up the real book title instead of
  the source-file basename.
- **OPF Metadata public init**: `OPFReader.Metadata` gained a
  public initializer so the importer can construct an updated
  metadata struct after AFM extraction.

### Deferred further

- ~~**Chapter classification on imported EPUBs**~~ shipped via
  the cheap-shortcut path. `EPUBImporter.buildMinimalChapter`
  extracts title (first `<h1>` or `<title>`, inline tags
  stripped) and ~800 chars of opening text from the first
  paragraph-bearing elements (`<p>` / `<h2>`–`<h6>` /
  `<blockquote>` / `<li>` — `<h1>` excluded since the title
  step already captured it). The result feeds
  `AppleFoundationModelClassifier`; the returned label is
  written into the resource's `<body>` opening tag through the
  new `BodyTypeInjector`. Conservative: existing publisher-set
  `epub:type` attributes are preserved.
- ~~**Coherence pass on imported EPUBs**~~ shipped via the
  **text-node-only path** (chose Option B over the doc's
  spec'd full XHTML → Chapter round-trip — same outcome at
  much smaller surface and zero risk of dropping publisher
  formatting). Three new pieces:
  - `Pipeline/CoherenceDigestSampler` builds digest-suitable
    `[Chapter]` from an `EPUBBook`'s spine resources by lifting
    the regex extraction `EPUBImporter.buildMinimalChapter`
    already used for chapter classification, raising the
    body-char cap to 2KB so the guardrail occurrence floor
    triggers on legitimately-recurring errors.
  - `Pipeline/XHTMLTextReplacer` does case-sensitive
    substring replacement only on character data between
    tags. Tags, attributes, `<script>` / `<style>` bodies,
    comments, CDATA, and PIs pass through byte-identical.
    No XHTML parser, no Chapter IR round-trip.
  - `ClaudeCoherenceAnalyzer` gained `docText(for:)` and
    `filterByGuardrails(suggestions:docText:)` public statics
    so the import path can reuse the same gating without
    going through `applyWithGuardrails`. Existing
    `applyWithGuardrails` now calls them internally (behavior-
    preserving refactor; 22 existing tests pass unchanged).
  - `EPUBImporter.runCoherencePass(on:)` wires it in after
    chapter classification, gated on
    `localFeatures.localCoherencePass` + AFM availability.
    AFM-only (matches the `runMetadataExtraction` posture —
    imports stay free; Cloud users get coherence on the
    conversion path).
  29 new tests across `CoherenceDigestSamplerTests` (12) +
  `XHTMLTextReplacerTests` (14) + analyzer additions (3).
  1027 tests pass total.
- ~~**Year / publisher / ISBN write-back**~~ shipped. AFM
  extracts all five front-matter fields; all five now write
  back. `OPFReader.Metadata` carries `year` / `publisher` /
  `isbn` slots; the reader parses `<dc:date>` (year prefix
  only — accepts bare year or full ISO timestamp),
  `<dc:publisher>`, and `<dc:identifier>` (URN-shaped or
  scheme-attributed, with hyphen stripping). The saver writes
  ISBN as a new `<dc:identifier>urn:isbn:VALUE</dc:identifier>`
  sibling — same shape the conversion path emits — and
  explicitly excludes the package's `unique-identifier`
  element from match candidates so the publishing identity
  stays untouched.
- **Settings → Library → Import section** with per-feature
  toggles. The existing `localFeatures.*` toggles already
  apply on import; when chapter-classification / coherence
  ship for imports, they'll respect the same Settings without
  a new surface.

This is the gap the importer closes: take any existing EPUB, give
it the structural marks Humanist relies on (paragraph anchors), put
it under `Books/`, catalog it, and build its embedding sidecar so
it joins the federated chat retrieval.

### Why bother

The library window has become a primary surface — bulk index,
multi-book chat with first-class citation jumps, scope picker,
exclusion. Every book added makes those surfaces more useful. But
the only on-ramp today is "convert a PDF I have," which excludes
the substantial set of books a user already owns as EPUBs.
Importing should be as cheap and obvious as conversion.

The importer also lets users round-trip Humanist EPUBs through
external editors / tools without losing library state — re-import
is idempotent.

### Scope

**`EPUBImporter` actor** — the orchestrator. Inputs: source EPUB
URL, target URL, optional toggles for which AFM passes to run.
Outputs: a Humanist-flavored EPUB at the target URL, a catalog
entry, an embedding sidecar.

Phases per book:

1. **Unzip + parse** via existing `EPUBBook.open(epubURL:)`. No
   re-architecture; the open path already handles standard EPUBs.
2. **Inject paragraph anchors** via a new
   `ParagraphAnchorInjector` — walks every spine resource's
   XHTML, assigns `hu-p-{chapterIdx}-{paraIdx}` to `<p>` elements
   that don't already have an `id`. Idempotent: re-importing an
   already-anchored book is a no-op.
3. **Optional `nav.xhtml` regeneration** — if the existing nav is
   flat / missing / broken, build one from the spine + chapter
   titles. Skipped when the source nav is well-formed.
4. **Save back** via `EPUBBook.save()` to the configured Books
   library directory.
5. **Catalog** via `LibraryStore.recordConversion(...)` — same
   entry shape, just `addedAt = now`.
6. **Optional AFM passes** — chapter classification, metadata
   extraction, coherence pass. Same factory pattern as the regular
   pipeline; gated by the existing `localFeatures` toggles.
   Cloud equivalents work too (when configured) for users who
   want pro-level metadata / classification on imported books.
7. **Build embedding sidecar** via `LibraryIndexBuilder.buildOne`
   — hierarchy + entity passes run as part of the same call.
   Imported book joins the federated index immediately.

**`ParagraphAnchorInjector`** — XHTML-walking helper:
- Parse via `XMLDocument` (already used elsewhere) or the same
  lightweight regex approach the existing chat pipeline uses
- Walk `<p>` elements in document order
- Assign `id="hu-p-{chapter}-{idx}"` only to elements that don't
  already have an `id`
- Re-emit XHTML with minimum-disruption formatting (don't
  reformat, just add the attribute)
- Same posture as the chat-pane's paragraph-extractor
  regex: pragmatic, isolated, easy to test

### Architecture

```
Sources/Pipeline/
├── EPUBImporter.swift             NEW — orchestrator
└── ParagraphAnchorInjector.swift  NEW — XHTML walker

Sources/Humanist/Library/
└── ImportEPUBProgressSheet.swift  NEW — UI for batch imports
```

`EPUBImporter` reuses every existing engine (the AFM /
Claude classifiers, the `LibraryIndexBuilder`, `EPUBBook.save`,
`LibraryStore.recordConversion`). The new code is a thin
orchestration layer + the anchor injector.

### Settings + UI

- **File → Import EPUB into Library…** menu command (⇧⌘I) —
  opens an `NSOpenPanel` accepting `.epub`, multi-select for
  batch import.
- **Library window action** — "Import EPUB(s)…" menu item next
  to the existing "Build Missing Indexes" / "Rebuild All
  Indexes" entries.
- **Drag-and-drop into Library window** — recognize `.epub`
  files dropped on the table and route to the importer rather
  than just opening one in an editor.
- **Progress sheet** — reuse the
  `LibraryIndexProgressSheet`-style pattern for batch imports
  (current N of M, per-book failure list, cancel button).
- **Settings → Library → Import section** — three toggles
  mirroring the AFM features: "On import, run on-device
  chapter classification / metadata extraction / coherence
  pass." Defaults match the runtime AFM availability — on
  when Apple Intelligence is enabled, off otherwise.

### Edge cases

- **Already-Humanist EPUBs** (re-import or round-trip): paragraph
  injector is idempotent — anchors don't duplicate. Catalog
  entry updates in-place rather than creating a duplicate row
  (`LibraryStore.recordConversion` already does this via the
  canonical-URL match).
- **Whole-book-in-one-XHTML**: anchor injection still works;
  treats the single spine entry as one "chapter." Editor's
  existing Split / Merge commands handle restructuring later
  if the user wants. Don't auto-split on import — too risky.
- **DRM-protected EPUBs**: detect at unpack time (Adobe ADEPT,
  Apple FairPlay, etc. fail to unzip cleanly); reject with a
  clear error. We don't strip DRM.
- **Malformed EPUBs**: pass through whatever `EPUBBook.open`
  raises — same surface the conversion path uses.
- **Existing `id` collisions**: `hu-p-` is namespaced with that
  prefix, so non-Humanist `id="..."` values pass through
  untouched.
- **Naming collisions in Books library**: `import.epub` from two
  different folders → same target filename. Resolution:
  append `(2)` etc., same approach as `nextAvailableHref`.

### Risks

- **XHTML normalization drift** — the injector re-emits the
  XHTML, which can lose formatting (whitespace, attribute
  order) that some EPUB readers care about. Mitigation:
  minimum-disruption injection (only add the `id` attribute on
  `<p>` elements that need it; don't reformat anything else).
- **Quality of imported EPUBs is whatever you put in.** AFM
  coherence pass can clean up recurring OCR errors but won't
  fix structural problems (missing chapter breaks, garbled
  text). Document this — imported EPUBs aren't magically
  improved.
- **Editor surface gracefully degrades on PDF-less books**.
  PDF pane shows "no source PDF," Re-OCR commands are inert,
  searchable-PDF sibling not produced. Test that all five
  panes load correctly without a paragraph-map sidecar.

### Effort

~2-3 days end-to-end:

- ~1 day: `ParagraphAnchorInjector` + `EPUBImporter` + tests
  (anchor idempotence, namespaced id collision avoidance,
  whole-book-in-one-XHTML, malformed input handling).
- ~0.5 day: UI surface (menu command, drag-drop, multi-select
  picker, progress sheet).
- ~0.5 day: Library cataloging + LibraryIndexBuilder
  integration.
- ~0.5 day: AFM-feature passes (classification + metadata +
  coherence) on import — gated by the existing toggles.
- ~0.5 day: Settings → Library → Import toggles + integration
  tests on real EPUBs.

### When to ship

Anytime; orthogonal to chat / vision-mode work. Strong fit since
R-Library-Chat-Plus shipped — the more books in the library, the
more value from "import everything I've already got" rather than
re-converting from missing PDFs. Particularly relevant for users
with pre-existing book collections (academics, archivists,
anyone with EPUBs that came from sources other than a PDF
they still have).

### What this isn't

- **Not a re-OCR path.** EPUBs that came from bad OCR stay bad-
  OCR'd until you run them through the regular PDF pipeline.
  The coherence pass catches recurring errors but won't fix
  systemic issues.
- **Not a structural restructurer.** We import what's there. The
  editor's existing Split / Merge / Move / Rename commands are
  the path for fixing structure post-import.
- **Not a way to convert *out* of Humanist's anchor scheme.**
  Anchors stay on export; non-Humanist EPUB readers ignore the
  `hu-p-` ids (no spec violation), so the EPUB is still
  portable to other tools.

### Dependencies

- `EPUBBook.open` / `EPUBBook.save` (shipped) for the round-trip.
- `LibraryStore.recordConversion` (shipped) for cataloging.
- `LibraryIndexBuilder` (shipped) for embedding sidecar build.
- AFM engines from L-Foundation-Models Phases 1+2 (shipped) for
  the optional polish passes.
- Editor's PDF-pane graceful-degradation path — likely already
  works for most fields but worth a focused QA pass.

---

## R-Library-Sync — Multi-machine library sharing via a cloud folder

**Status**: Phases A + B shipped. A single
"Share library across machines" toggle in Settings → Conversion
moves the catalog (library.json + collections), the embedding /
hierarchy / entity sidecars (keyed by stable catalog UUID
instead of path SHA-256), and the alias dictionary from
`~/Library/Application Support/Humanist/` to
`<outputRoot>/.humanist/`. A second Mac sharing the folder via
iCloud / Dropbox / SyncThing reads the same files; book paths
resolve through per-entry `relativePath` against the local root.

Auto-catalog on editor-open ensures every EPUB the user touches
gets a stable UUID for sidecar keying — a deliberate scope
expansion of "the library is for books I converted in this app"
to "the library knows about every EPUB you've opened." Per-book
chat transcripts, the conversion queue, and per-app preferences
intentionally stay machine-local.

### Why bother

Real workflows: research at the office, edit at home; a multi-Mac
household; quick failover to a backup machine when the primary
is in for repair. The user already has the obvious instinct
("just point both at the same folder") and Humanist already has
all the right plumbing in pieces — what's missing is making the
on-disk shapes location-portable instead of absolute-path-locked.

The current "lite sharing" path (share `Books/`, accept that each
machine indexes / chats independently) is useful but expensive:
re-indexing a 200-book library against a Cloud embedding backend
costs real money, and re-asking "which books discuss biopolitics?"
re-reads the same answers from scratch.

### Today's failure modes (what breaks when you share a folder)

- **`library.json` lives in `~/Library/Application Support/`**,
  outside the shared output root. Each machine has its own
  catalog file. Even symlinking it doesn't help by itself —
- **`LibraryEntry.epubURL` is canonical-absolute**. Machine A's
  rows reference `/Users/tim/Documents/Humanist Library/Books/X.epub`;
  machine B (different home dir, or just a different output
  folder) sees those paths as nonexistent. `recordConversion`'s
  dedup-by-canonical-URL match never fires, and `OpenRouter.open`
  fails on missing files.
- **Sidecar files keyed by absolute-path SHA-256**.
  `~/Library/Application Support/Humanist/{Chats,Embeddings}/<sha256>.json`
  hashes the canonical EPUB path. Different path → different
  hash → both machines treat the same EPUB as a fresh book on
  first open. Library chat sees zero indexed books on machine B
  even though machine A built every sidecar.
- **Alias dictionary, queue snapshot, recents** all live in
  Application Support, all per-machine. Some of those should
  stay per-machine (queue, recents); others (aliases) should
  travel with the library.
- **iCloud lazy-download**: opening a book on machine B when
  iCloud hasn't materialized the file yet — `EPUBBook.open`
  fails with a not-found error. Surfacing a useful message ("not
  yet downloaded from iCloud, try again in a moment") is part
  of the design.

### Scope: three independent decisions

**Decision 1 — Where catalog state lives.**

Move `library.json` (catalog + collections) into the output root
when one is configured. Path: `<outputRoot>/.humanist/library.json`
or `<outputRoot>/Humanist Library.json` — visible vs hidden is a
taste call; the dotfile form keeps the user's folder browsing
uncluttered. Application Support stays the fallback when no
output root is set (current behavior). On launch, if both files
exist, the in-root one wins — that's the source of truth a user
who opted into sync expects.

**Decision 2 — How book identity flows.**

Store EPUB references as a *relative path from the output root*
when the file lives inside it; fall back to canonical-absolute
when it doesn't. The migration helper rewrites existing
absolute paths in place when the first launch under the new
shape detects them sitting under the configured root.

`LibraryEntry.epubURL` becomes a `LibraryEntry.epubLocation`
that's either `.relative(String)` or `.absolute(URL)` — `Codable`
on a tagged-union shape. The resolver method on `LibraryStore`
returns the absolute URL by combining with `currentRoot()` for
the relative case.

**Decision 3 — Sidecar storage keys.**

Switch `EmbeddingsSidecarStore` and `ChatTranscriptStore` from
"path SHA-256 → file" to "`LibraryEntry.id` (UUID) → file". The
UUID is already stable across machines (it's in the synced
catalog). Sidecar files live in `<outputRoot>/.humanist/embeddings/<uuid>.json`
when sync is active; Application Support is the fallback.

This turns "book identity" from a filesystem fact into a catalog
fact. A book imported on machine A gets a UUID; sharing the
catalog shares the UUID; sidecar lookup on machine B finds the
same file via the same UUID.

### Per-machine vs shared classification

| File / state | Shared | Per-machine |
|---|---|---|
| `library.json` catalog + collections | ✓ | |
| Per-EPUB sidecars in META-INF | ✓ (in EPUB) | |
| Embedding + hierarchy + entity sidecars | ✓ | |
| Alias dictionary | ✓ | |
| Per-book chat transcripts | | ✓ |
| Library chat transcript | | ✓ |
| Conversion queue snapshot | | ✓ |
| Recents (last 10 menu) | | ✓ |
| Job runner state | | ✓ |
| Apple Foundation Models output folder | | ✓ |
| All `@AppStorage` settings (AI / chat / conversion / appearance) | | ✓ |

Rationale for chat transcripts staying per-machine: the
conversation you had on your office Mac is *your* conversation;
syncing it to a household Mac the kids also use is the wrong
default. The embedding *index* is expensive to rebuild and is
the right thing to share; the *transcript* is cheap context and
the right thing to keep local. Settings stay local too —
"Private mode" might be on at home and off at the office; same
for cost caps.

### Architecture sketch

```
Sources/Humanist/Library/
├── LibraryStore.swift              CHANGED — Codable EpubLocation enum;
│                                    catalog file path resolution; one-time
│                                    migration; @Published flag for whether
│                                    the store is in shared mode.
├── EpubLocation.swift              NEW — tagged-union .relative / .absolute,
│                                    Codable, resolver helpers.
└── LibraryMigration.swift          NEW — one-shot migration that rewrites
                                     absolute → relative for files inside the
                                     output root and renames sidecar files
                                     from sha256-keyed to UUID-keyed.

Sources/Humanist/Editor/Chat/
├── EmbeddingsSidecarStore.swift    CHANGED — key by LibraryEntry.id when
│                                    sync mode is active; sha256-keyed
│                                    fallback for legacy unshared libraries.
└── ChatTranscriptStore.swift       CHANGED — same key migration but
                                     transcripts stay in Application Support
                                     (per-machine).
```

### Settings

A single `Sync library catalog across machines` toggle in Settings
→ Conversion. Effective only when an output root is configured;
flipping it on triggers the migration helper. Surface a one-time
sheet on first activation explaining what travels vs what stays
local, with an opt-out and a "where do I find my chat history if
I roll back?" line.

No multi-master conflict resolution — last-writer-wins on
`library.json` via atomic writes. iCloud handles the
"machine B's queued changes apply when it comes online" case;
collisions are rare for a single user across two machines and not
worth a CRDT.

### Migration

One-shot, triggered when the user flips the sync toggle on:

1. Snapshot the current catalog.
2. For each entry whose `epubURL` sits under the configured
   output root, rewrite it as a relative path.
3. For each existing sidecar in `Application Support/Humanist/{Chats,Embeddings}/`,
   look up the matching `LibraryEntry` by old-path SHA-256, and
   rename / move the file to UUID-keyed shape (embeddings →
   `<root>/.humanist/embeddings/<uuid>.json`; chats stay in
   Application Support but switch to UUID-keyed filenames).
4. Move `library.json` from Application Support to the output
   root. Leave the old one behind for one launch as a backup;
   delete on the next confirmed successful launch.
5. Mark the migration done via a UserDefaults flag so re-runs
   are no-ops.

### Risks

- **iCloud lazy-download race**: opening a book whose data
  isn't materialized yet. Mitigation: detect the
  `NSFileProviderItemFlags.downloading` state and surface a
  "waiting on iCloud" indicator; if `EPUBBook.open` fails with a
  not-found error, hint at the iCloud cause specifically rather
  than the generic missing-file message.
- **InputFolderScanner FS-event storms** under cloud sync. The
  watcher already debounces 400ms; cloud sync can produce
  rapid-fire events as files appear. Verify the debounce holds;
  consider extending to 1s for sync mode.
- **Conflicting catalogs after offline edits on both machines**:
  e.g., machine A adds book to "Foucault" collection while
  machine B adds different book to same collection, offline.
  iCloud picks last-writer-wins, one set of edits is lost.
  Acceptable for v1 — document the limitation and recommend
  not editing collections on both machines while one is
  offline. CRDT or three-way merge is a v2 problem.
- **Embedding sidecars built with different backends**: machine
  A indexed against Voyage; machine B's Settings have Apple
  NLEmbedding. Sidecar dimension / backend mismatch is already
  handled today (federation drops mismatched books) but worth
  testing in the sync scenario specifically.
- **The "different home dir" canonical URL trap**:
  `URL.canonicalForFile` expands `/var` → `/private/var` on
  macOS; relative paths sidestep this completely, which is one
  of the reasons to switch.

### Effort

~2-3 days end-to-end:

- ~0.5 day: `EpubLocation` enum, Codable, resolver helpers,
  `LibraryStore` API updates.
- ~0.5 day: Sidecar stores migrate to UUID keying with sha256
  fallback for unmigrated catalogs.
- ~0.5 day: One-shot migration helper + safety net (backup of
  the old library.json + sidecars).
- ~0.5 day: Settings toggle + first-activation explanation
  sheet + iCloud-not-ready surfacing.
- ~0.5 day: Tests — migration round-trip, relative-path
  resolution, sidecar key migration, mixed local + shared
  catalogs (some books outside the output root).
- ~0.5 day: Manual two-machine soak — set up iCloud Drive,
  add books on one, verify catalog + collections + chat
  index visible on the other.

### When to ship

After R-EPUB-Import follow-up's deferred items (chapter
classification + coherence on import) settle — those touch the
sidecar build path that this entry rekeys. Sequencing the rekey
before the deferred AFM work means two migrations; sequencing
after is one combined change.

Strong fit when a second Mac enters the picture (which the user
has explicitly raised as a use case). Doesn't help users with
exactly one machine, so it's not on the critical path for the
"first paid customer" feature set.

### What this isn't

- **Not real-time collaborative editing.** Two users editing
  the same EPUB at the same time has all the merge problems of
  any text editor; out of scope. iCloud serializes file writes
  in practice; that's good enough for a single user across two
  machines.
- **Not cross-user sharing.** Sync within one Apple ID's
  iCloud or one shared Dropbox account. Different users
  (different Apple IDs) is a "publish + import" workflow, not
  sync.
- **Not iCloud-specific.** The implementation reads + writes
  files; whatever syncs the folder (iCloud, Dropbox,
  SyncThing, a network share, even rsync via cron) just works.

### Dependencies

- Configured output folder feature (shipped) — sync only
  activates when a root is set.
- `LibraryEntry.id` UUIDs (shipped) — the sidecar rekey
  depends on these being stable across machines, which they
  are: created at `recordConversion` time and persisted.
- `EmbeddingsSidecarStore` (shipped) — gains an optional
  alternate storage root + UUID-keyed filename strategy.
- A one-shot migration helper — new code, but a familiar
  shape (the LibraryStore catalog-format wrapper from
  Collections used the same "read legacy, write new" pattern).

---

## R-Auto-Collections — Generate Collections from catalog metadata

**Status**: Phases 1 + 2 shipped. Type / Author / Genre auto-
collections all materialize from catalog metadata; Genre runs
through Apple Foundation Models (Phase 4 of L-Foundation-Models).

### Why bother

A 1000-book library is too big to organize manually. Three
natural pivots emerge from the metadata we already have:

- **Type**: Print / Manuscript / Early Print / Digital. The
  conversion or import path that produced the book is a
  stable, useful category. Especially valuable for a user
  doing serious research across material types.
- **Author**: When the catalog carries 3+ books by the same
  person, "all my Foucault" is a real workflow.
- **Genre**: Poetry / Philosophy / History / Fiction (with
  sub-genres) / etc. Less clean than Type or Author (requires
  classification) but the most user-recognizable filing
  taxonomy.

The user creates manual `BookCollection`s today via R-Library-
Chat-Plus Tier 1. Auto-collections layer on as a parallel set
of system-generated groupings.

### Phase 1 — Type + Author (shipped)

Deterministic, no model needed.

- `BookConversionType` enum: `print` / `earlyPrint` /
  `manuscript` / `digital`. Stamped on `LibraryEntry.conversionType`
  at conversion (JobRunner) and import (EPUBImporter) time.
- Backfill heuristic during `LibraryStore.load`: legacy
  entries without a stamp get `.print` when a sibling .pdf
  exists, `.digital` otherwise.
- `LibraryEntry.author` field — populated from
  `<dc:creator>` at catalog time alongside title.
- `AutoCollectionSource` discriminator on `BookCollection`:
  `.byType(BookConversionType)` or `.byAuthor(String)`. Manual
  collections have `nil`.
- `LibraryAutoCollections.refresh(library:)` regenerates auto-
  collections from current catalog state. Author threshold
  configurable via Settings → Conversion (default 3).
  Idempotent — re-runs preserve auto-collection ids so
  SwiftUI selection state doesn't bounce.
- Library window sidebar grows three sections: "My
  Collections", "Auto: by Type", "Auto: by Author".
  Auto-collections get a category-specific icon (tag for
  type, person for author) and their context menu hides
  Rename/Delete (a refresh would regenerate them anyway).
- "Refresh auto-collections" button next to the New
  Collection button in the sidebar header.

10 new `LibraryAutoCollectionsTests` cover type bucketing,
author-threshold honoring, idempotent re-runs preserving ids,
user-collection preservation, drop-when-empty, Codable
round-trip with legacy decoding fallback.

### Phase 2 — Genre via AFM (shipped)

Closed-taxonomy classifier added as the third AFM use case
alongside Phase 1 (chapter classification) and Phase 2
(metadata extraction). Documented as **L-Foundation-Models
Phase 4: Genre classification**.

**Scope**:
- `BookGenre` enum: closed taxonomy with single-sublevel
  hierarchy. Draft top-level set (~15 cases):
  - poetry, drama, philosophy, religion, history,
    biographyMemoir, science, socialScience, reference,
    education, arts, travel, howTo, children, uncategorized
  - **Fiction sub-genres** (single sublevel only):
    fictionLiterary, fictionFantasy, fictionScienceFiction,
    fictionMystery, fictionRomance, fictionHorror,
    fictionHistorical
  - Flat enum (not nested) for AFM's schema-guided
    constraint; computed `topLevel` property reconstructs
    the hierarchy for sidebar display.
- `BookGenreClassifier` — new AFM-based engine modeled on
  `AppleFoundationModelClassifier`. Schema-guided closed
  enum; input = title + author + ~200 chars opening text;
  output = one `BookGenre` case (or nil for uncategorized).
- `LibraryEntry.genre: BookGenre?` field. Stamped at
  conversion / import time alongside the existing AFM
  metadata + chapter classifier passes — same gating
  (`AppleFoundationModelClient.availability` + opt-in
  Settings toggle).
- `AutoCollectionSource.byGenre(BookGenre)` case added.
- `LibraryAutoCollections.refresh` learns to materialize
  genre collections: one collection per non-empty top-level
  genre + one per Fiction sub-genre. Sidebar grows a fourth
  section: "Auto: by Genre".
- Settings: toggle to disable genre auto-classification (for
  users who don't want AFM running on every book).

**Why AFM, not Haiku**: closed-enum classification with small
input is exactly AFM's sweet spot (mirrors Phase 1 chapter
classifier). Free + on-device fits the "once per book across a
1000-book library" cadence. Haiku's marginal world-knowledge
advantage doesn't outweigh ~$1/library cost when the bucket-
level decision is robust to small label errors.

**Timing**: classify at conversion / import time (free pass).
On-demand refresh ("Regenerate genre" command) for back-fill
on existing libraries — walks unstamped entries, runs the
classifier, persists. ~30-50 minutes for 1000 books at AFM's
2-3 sec/book pace; surface progress + cancel.

**Effort**: ~1 day end-to-end. The classifier is a copy-paste
of the chapter classifier with a different `@Generable` enum.
Plumbing (stamp + auto-collection generation + sidebar) is
incremental on Phase 1's existing scaffolding.

**Not in scope**: open-string-tag genres (drift over time);
deeper hierarchy (single sublevel only per user direction);
per-book genre override UI (the classifier's call stands;
re-running with a different prompt or model is the path if
needed).

### Open questions for Phase 2

- Should the classifier's "uncategorized" output materialize
  a collection ("Uncategorized") or be silently dropped?
  Probably drop; the user can see uncategorized books in
  "All Books" + the absence of a genre row implicitly tells
  them.
- Re-classification on book metadata change (title / author
  updated after a re-import) — opt-in or automatic? Probably
  automatic at the next refresh; the classifier is cheap.
- Confidence threshold? AFM returns a single label; we don't
  get a confidence score back. Could read the model's
  uncertainty by asking for two top candidates, but adds
  complexity. v1 takes the single answer.

---

## R-Metadata-Online — Import book metadata from online sources

**Status**: v1 + v1.5 shipped (commits `2820d07`, `6363f30`,
`d1e24b5`). PLANS hadn't been updated to reflect it; corrected
2026-05-12 after the user flagged.

**What landed (v1, v1.5, cover follow-on)**:
- `Sources/Humanist/Library/MetadataOnline/` — new directory
  housing the lookup surface.
- `MetadataOnlineLookup.swift` — `MetadataQuery`,
  `MetadataCandidate` (id, title, author, publisher, year,
  isbn, language, coverImageURL, sourceName, sourceURL),
  `MetadataSource` protocol, `MetadataSourceError`.
- `OpenLibrarySource.swift` — adapter against
  `openlibrary.org/search.json`. URLSession-injectable for
  tests; defensive decoder; capped at 10 results per query.
- `GoogleBooksSource.swift` — adapter against
  `googleapis.com/books/v1/volumes?intitle:…+inauthor:…`.
  Picks ISBN_13 over ISBN_10, extracts 4-digit year from
  `publishedDate`, sanitizes cover URLs (strips `&edge=curl`,
  http→https). Optional API key threaded through so the
  field can plug in later from Settings without a refactor.
- `MetadataLookupCoordinator` — fans queries to every source
  concurrently via `TaskGroup` with a 5s per-source timeout
  (slow source doesn't stall the picker). Per-source failure
  is non-fatal — errors collect in `partialErrors`; picker
  shows a soft orange banner ("Google Books unavailable")
  while still rendering whichever sources responded. Merge
  fuzzy key = first-5-title-words + author last name
  (handles "Foucault, Michel" vs "Michel Foucault" and
  prefix-vs-subtitle title variants); cross-source duplicates
  collapse into one row whose badge joins source names
  ("Open Library · Google Books"). Ranks by agreement count
  desc, then preserves intra-source rank.
- `MetadataLookupSheet.swift` — picker UI. Pre-fills query
  from the editor's current title/author + auto-runs on
  appear; ⌘↩ re-searches; idle / searching / empty / failed /
  results states; per-row preview (title, author · year ·
  publisher, ISBN, language, source badge, AsyncImage cover
  thumbnail 36×52pt); double-click or Use Selected accepts;
  ⌘. cancels.
- `MetadataEditorSheet` integration — "Look up online…"
  header button opens the picker. `onAccept` populates title +
  author + prepends the candidate's language to the editor's
  state. Genre / conversionType stay untouched (no
  OPF / source representation for those).
- `LibraryCoverOverrideStore` (cover follow-on) — keyed by
  library entry id, stored at
  `<storeDir>/.humanist/Covers/<libraryID>.jpg`. Atomic
  writes; `download(from:for:)` fetches an HTTP URL with
  non-2xx / empty-body errors surfaced. iCloud-syncing across
  machines via the existing catalog path. Reversible —
  delete the file and the EPUB-embedded cover comes back.
  `CoverImageCache.image(for:libraryID:)` gained an
  optional `libraryID` and checks the override path before
  falling through to the EPUB-cover extractor; same
  downsampling pipeline for both paths so quality is
  consistent.

**Still pending**:
- **v1.7 — Claude-search consolidator** (~½ day). For
  non-modern / classical / manuscript material the open APIs
  return weak hits. A Claude-backed `MetadataSource` impl
  would gather looser hits, consolidate, and rank. Cloud
  Phase 1 plumbing exists; the work is one prompt + one
  wire type. Build when manuscript / Early Print users
  actually reach for it.
- **v2 — bulk-mode multi-select lookup** (~1.5 days). "Look
  up metadata for selected books" command in the Library
  filter bar / toolbar. Different UX from per-entry: auto-
  accept high-confidence matches (single candidate, 2+ source
  agreement, title Levenshtein ≤ 0.1, author last-name
  match); queue ambiguous matches for end-of-run review;
  skip no-result books silently with a count in the
  completion summary. Independent of v1; ship after the
  per-entry flow is in daily use and the hit rates settle.

Sections below preserved as design rationale for v1.7 / v2.

### Why bother

The current pipeline pulls title / author / year / publisher /
ISBN from inside the book (Q-Metadata via Haiku, then the
R-EPUB-Import OPF write-back). That's authoritative when the
front matter is clean; it falls down hard on:

- Manuscript / Early Print material that doesn't carry
  modern bibliographic front matter at all.
- OCR runs where the title page came through illegible and
  the model returned `null`s.
- Books the user imported as a pre-converted EPUB whose OPF
  someone else filled out wrong.
- Editions where the publisher matters for citation
  (Oxford Classical Texts vs. Loeb vs. Teubner) and the
  in-book metadata doesn't surface the imprint.

The metadata editor (shipped) lets the user type corrections
in by hand. The next step is "fetch the corrections for me" —
look up by title + author or by ISBN, present candidates, let
the user pick one, write all matching fields into the entry.

This is a Tier 9 quality feature, not a near-term must-have,
but the editor work has now built the obvious anchor point.

### Sources to evaluate

Open / free-tier, no API keys required, queryable without
auth — preferred. Each has different strengths; the right
posture is "ask 2-3 in parallel, present a merged candidate
list."

- **Open Library API** (`openlibrary.org/search.json` and
  `/api/books?bibkeys=ISBN:...`). Free, no key. Strong on
  English-language books with ISBNs; weaker on academic
  monographs and non-Latin scripts. Returns title / authors /
  publishers / publish_date / subjects / cover image URLs.
- **Google Books API** (`googleapis.com/books/v1/volumes?q=...`).
  Free tier without key (rate-limited to ~1000/day); a key
  raises the cap. Best general-purpose coverage; strong
  multilingual support. Returns industryIdentifiers,
  publishedDate, publisher, categories, language, plus
  cover thumbnails.
- **WorldCat Search API** (`worldcat.org/webservices/...`).
  Requires registration + a wskey. Best for older academic
  material and editions / printings. Worth integrating only
  after the open sources prove insufficient.
- **Library of Congress catalog** (`id.loc.gov/`). Useful for
  authority records (canonical author name forms, LC subject
  headings) more than book records. Could feed a "normalize
  author name" pass.
- **CrossRef** (`api.crossref.org/works`). DOI-based — barely
  applicable to books-as-EPUBs, but valuable for the subset
  of academic books with assigned DOIs. Returns ISBN +
  publisher + year cleanly.
- **OCLC's xISBN** — deprecated; skip.
- **Wikidata SPARQL** — overkill for v1 but the only source
  with strong coverage of historical / pre-1900 imprints and
  manuscript shelfmarks. Worth a follow-on after v1 lands.

For non-English / classical / manuscript material specifically,
the right answer is probably **a Claude call against a search
result**, not a pure API hit. The model gathering loose hits
from Google Books + Open Library + arXiv + library catalogs
and consolidating beats trying to fit medieval Latin / Greek
into Google Books' schema.

### Goal

A "Look up online…" button in the metadata editor sheet that
asks the user for query terms (defaulted from the entry's
current title + author), fans out to two or three sources,
shows a candidate-picker, and on selection populates the
editor's fields without dismissing the sheet (so the user
can still edit before Save).

Pre-ISBN material gets a separate ISBN entry field in the
candidate picker — if the user picks a candidate that has
an ISBN we'd previously failed to extract, the Save writes
it back into the OPF (existing `EPUBBookSaver`
`updateMetadataInPlace` path; the ISBN-doesn't-clobber-
unique-id invariant already documented under R-EPUB-Import).

### Approach

Three layers:

1. **`MetadataSource` protocol** in a new `Sources/Pipeline/
   MetadataLookup/` directory. One method:
   `func query(_ q: MetadataQuery) async throws ->
   [MetadataCandidate]`. Concrete impls
   `OpenLibrarySource`, `GoogleBooksSource`, and (later)
   `ClaudeSearchSource`. Each source maps its wire format to
   a shared `MetadataCandidate` struct (title, author,
   publisher, year, isbn, subjects, coverImageURL,
   sourceName, sourceURL).
2. **`MetadataLookupCoordinator`** — fans queries out to the
   configured sources in parallel via `async let` / task
   group; merges results via title+author fuzzy key
   (Levenshtein on lowercased title, last-name match on
   author); ranks merged candidates by source agreement
   (a candidate with hits in 2 sources outranks a singleton).
   Per-source timeouts so a slow upstream can't stall the UI.
3. **`MetadataLookupSheet`** — UI layer presented from inside
   `MetadataEditorSheet`. Lists candidate matches with source
   badges; clicking "Use this" populates the editor's fields
   and dismisses the lookup sheet but not the editor. Empty-
   result + error states surface plainly; per-source errors
   collected into a "failed sources" footer rather than
   blocking the whole lookup.

### Tricky bits

- **Author normalization**: source results return "Foucault,
  Michel" or "Michel Foucault" or "Foucault, M." — need a
  shared lastname-firstname normalizer before fuzzy match.
  Reuse / extend the existing `AuthorNameNormalizer`
  (R-Auto-Collections Phase 1).
- **Multi-volume / multi-edition**: a single search may hit
  five editions of "Discipline and Punish." The picker must
  show edition / publisher / year prominently so the user
  can pick the right one. Probably also surface "this is one
  of N editions found" so the user knows there's a choice
  being made.
- **Rate-limiting**: Google Books without a key throttles at
  ~1000/day. The user could plausibly batch-lookup an entire
  library; we'd need a per-source rate counter + cooldown.
  Simplest v1: per-day in-memory counter + an explicit cap
  alert. v2 would add an optional API key field in Settings.
- **No-result handling**: a real failure mode for manuscript /
  pre-1900 material. The picker needs a clean "no matches —
  try a different query" path that doesn't look like a bug.
- **PII / network egress**: the user has historically wanted
  Private mode as a real option. Lookup is network-dependent
  by definition, so this feature needs a Settings toggle and
  a per-call confirmation when the user is in Private mode
  (or the button disables entirely with a "Cloud-mode only"
  hint). The query payload itself — title + author — is
  user-typed and going to a public catalog API, so the
  privacy story is roughly "this is a Google search, not a
  cloud-AI call," but the toggle still belongs.
- **Cover-image fetching**: Open Library returns cover URLs;
  Google Books returns thumbnail URLs. Tempting to refresh
  the EPUB cover from a high-res match, but EPUB cover
  replacement is its own surface (read OPF, replace the
  referenced image file, update manifest item). Defer to a
  v2; v1 just stores the cover URL in `MetadataCandidate`
  for the picker thumbnail.

### Bulk-mode follow-on (v2)

After the per-entry editor flow works, a "Look up metadata
for selected books" command becomes natural. Same pipeline,
but driven from the Library window's filter-bar (alongside
Bulk Edit / Chat with Selected / Remove). Per-book picker
would be too tedious for 50 books at once, so the bulk mode
needs different UX:

- **Auto-accept high-confidence matches** (e.g. a single
  candidate that hit in 2+ sources with title Levenshtein
  ≤ 0.1 and author last-name match).
- **Queue ambiguous matches** for user review (sheet at the
  end showing 5 books that need a pick).
- **Skip no-result books** silently; surface count in the
  completion summary.

The bulk path is independent of v1; ship the per-entry
editor lookup first and let the bulk shape settle once we
see real hit rates.

### Risks

- **Source schema drift**: free APIs change without notice.
  Each `MetadataSource` impl needs defensive decoding +
  unit tests fixtured against captured real responses; treat
  any source-side failure as "skip this source, fall through"
  rather than failing the whole lookup.
- **Wrong-edition drift**: confidently picking the wrong
  edition silently corrupts metadata. The picker UX must
  show enough provenance for the user to notice — at
  minimum, the source's URL alongside each candidate so they
  can click through and verify.
- **Scope creep into "manage my entire library from this
  feature"**: the metadata-import work invites a "while we're
  here, let's also fetch series info / awards / Goodreads
  ratings" expansion. Resist. The feature is "fill in the
  fields we already have"; everything else is a separate
  surface.

### Effort estimate

- v1 — single-source Open Library lookup wired into the
  editor sheet: ~1 day.
- v1.5 — second source (Google Books) + merging /
  ranking: ~0.5 day.
- v1.7 — Claude search consolidator for non-modern
  material: ~0.5 day (Cloud-Phase-1 plumbing already
  exists; this is one new prompt + one new wire type).
- v2 — bulk-mode multi-select lookup with auto-accept:
  ~1.5 days.

Total to ship-ready single + multi source: ~2 days.
Total including Claude consolidator and bulk mode: ~3.5
days.

### Dependencies

- Metadata editor sheet (shipped).
- `Sources/Pipeline/ClaudeMetadataExtractor.swift` (shipped)
  for the prompt shape — the Claude-search consolidator
  reuses the same JSON schema.
- `AnthropicAPIClient` (Cloud Phase 1, shipped) for the
  search-consolidator path.
- Settings → Library → "Online metadata lookup" toggle
  (new). Default on; Private-mode users can flip it off
  to silence the editor's lookup button entirely.

### Open questions

- Default source set? Open Library + Google Books with no
  key is probably the right v1; the user can layer a key on
  later if they hit rate limits.
- Claude consolidator: gate it behind a separate toggle
  ("Use AI to find harder-to-match books") so the user
  knows when a network round-trip becomes a Claude call?
  Probably yes — the cost / latency profile is different
  enough to merit visibility.
- Save UX: should the lookup-picker autosave on selection
  (replacing the current editor state immediately and
  closing both sheets) or just populate the editor (current
  plan)? Populate is safer — the user gets a last look
  before commit; one extra click is the right price for
  not accidentally accepting a wrong edition.

---

## R-Chat-Graph-Lite — Hierarchical + entity graphs for chat retrieval

**Status**: substantively complete. Hierarchy primitive, multi-book
chat scope, `BookEntityIndex` / `LibraryEntityIndex`, four-way RRF
fusion, alias dictionary, and Settings toggles all shipped. The
only remaining piece is section-level granularity — see "Still
pending" below; build only if chapter-level expansion proves too
coarse in practice.

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

**Status**: Manuscript track v1 + Early Print track v1 shipped.

Both tracks wire through the existing `ClaudePageOCREngine` via
a `Mode` enum:

- `.typeset` (Sonnet 4.6) — original Claude OCR path for modern
  printed material with no orthography quirks.
- `.earlyPrint(typeface: EarlyPrintTypeface)` (Sonnet 4.6) —
  same model as typeset, different prompt: fluent normalization
  of long-s, u/v, i/j, standard ligatures; preserves period
  spelling otherwise; skips catchwords + signature marks. Four
  typeface sub-modes: auto / romanAntiqua / blackletterFraktur
  (German + early English incunabula, eszett / round-r / umlaut
  handling) / italic.
- `.manuscript(hand: ManuscriptHand)` (Opus 4.7) — Opus-routed
  diplomatic transcription for handwritten material. Five sub-
  modes: auto / diplomatic (16th–17th c. secretary) / roundHand
  (18th c. copperplate) / cursive (19th–early 20th c.) /
  contemporaryInformal.

Pivoted from the original "Gemini Pro for Early Print" spec —
the model wasn't the real lever; the prompt's normalizing vs.
diplomatic posture is. Sonnet with a tuned prompt delivers the
same user-visible contrast at a fraction of the implementation
cost (reuses every line of prefix cache, batch dispatch, error
handling, capture-sink plumbing). Model swap to Gemini later is
a one-line change if testing data justifies it.

Launcher shows three mutually-exclusive toggles in row 2 —
"Claude OCR ($$$)", "Early Print ($$$)", "Manuscript ($$$$)" —
with a sub-picker row that appears below when Early Print
(Typeface:) or Manuscript (Hand:) is on. Per-job;
intentionally not Settings defaults.

Validation spike deferred per user direction (testing priority).
Prompts grounded in paleographic + early-printing conventions;
each sub-mode addendum is independently tunable based on real
tester feedback.

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

## L-Foundation-Models — On-device classification for Private mode

**Status**: Phases 1 + 2 (mostly) shipped. Phase 1 — chapter
classification — landed in commit `727d379`. Phase 2 — metadata
extraction + coherence pass — landed alongside this entry. The
remaining Phase 2 piece (post-OCR cleanup) is deferred behind a
clearer integration point; see the "Still pending" section below.
Phase 3 (TOC parsing) is still on the runway.

The codebase already targets macOS 26 (per `Package.swift` and the
macos-26-only memory), so the framework floor is met. Today every
Cloud-mode feature is gated behind an Anthropic key — Private-mode
users get the cascade OCR and that's it: no chapter classification,
no metadata extraction, no post-OCR cleanup. AFM fills most of that
gap, on-device, free, no key.

### What landed in Phase 1

- **`AppleFoundationModelClient`** (`Sources/AI`): thin wrapper
  over `FoundationModels`. Static `availability` property bridges
  `SystemLanguageModel.default.availability` into a Sendable
  `Availability` enum. `respond(instructions:prompt:generating:)`
  is the one schema-guided entry point — each call constructs a
  fresh `LanguageModelSession` (sessions accumulate transcript
  context, which is helpful for chat but actively counterproductive
  for classification where every chapter should be scored against
  the same fixed instructions).
- **`AppleFoundationModelClassifier`** (`Sources/Pipeline`):
  conforms to a new `SemanticChapterClassifier` protocol. Uses a
  `@Generable enum EpubChapterLabel` to constrain on-device output
  to one of the 16 EPUB 3 structural-semantics tokens — the schema
  guidance means parsing succeeds without the post-hoc
  normalization the Cloud path needs. Mirrors
  `ClaudeChapterClassifier.makeContext` for prompt construction,
  so cross-impl quality comparisons are apples-to-apples.
- **Pipeline routing**: new `makeChapterClassifier` factory picks
  Cloud (when configured + key + budget) or AFM (when Private +
  toggle on + Apple Intelligence available); both impls feed the
  same `classifyChapters` fan-out which now takes the protocol
  type. `ClaudeChapterClassifier` retroactively conforms; nothing
  in the Cloud path changes.
- **`AISettings.LocalFeatures`**: new sibling of `CloudFeatures`
  with `localChapterClassification` (default on). Decoded
  optionally so settings persisted before this field existed
  round-trip cleanly.
- **Settings UI**: a new "Local AI" section appears under Private
  mode. When `LanguageModelSession.availability == .available`
  the toggle is live; when unavailable, the section shows a
  one-line notice + the framework's reason string + a hint to
  enable Apple Intelligence in System Settings.

### What landed in Phase 2

- **`AppleFoundationModelMetadataExtractor`**: front-matter →
  `@Generable struct BookMetadata` with the canonical 5 fields
  (title, author, year, publisher, ISBN). Schema-guided output
  means parsing succeeds without the JSON-fence stripping the
  Cloud path needs. Year + ISBN normalization reuses the Cloud
  impl's helpers verbatim.
- **`AppleFoundationModelCoherenceAnalyzer`**: same 8 KB digest
  the Cloud path consumes (well within AFM's context window),
  output is a `@Generable struct CoherenceSuggestions` with up
  to 10 `{wrong, right}` pairs. Reuses
  `ClaudeCoherenceAnalyzer.applyWithGuardrails` +
  `buildDigest` so pre/post processing is identical between
  impls — only the model call differs.
- **Shared protocols**: `BookMetadataExtractor` and
  `BookCoherenceAnalyzer` parallel `SemanticChapterClassifier`
  from Phase 1. Cloud impls retroactively conform; pipeline
  factories `makeMetadataExtractor` and `makeCoherenceAnalyzer`
  pick Cloud / AFM / nil based on the same gating policy as the
  classifier factory.
- **`AISettings.LocalFeatures`** gained `localMetadataExtraction`
  and `localCoherencePass` (both default on). Settings UI shows
  three toggles + descriptions under the Local AI section when
  Apple Intelligence is available.

### What landed in Phase 4 (Genre classification)

- `BookGenreClassifier` in Pipeline — schema-guided
  `@Generable` enum constraint, takes title + author + ~600
  chars opening text, returns one `BookGenre` case. Closed
  taxonomy of 32 cases spanning humanities + technical
  material (math, science sub-genres, technology including
  Computing). Mirrors Phase-1 chapter classifier shape exactly.
- Powers R-Auto-Collections Phase 2: EPUBImporter runs at
  import time; `LibraryAutoCollections.classifyMissingGenres`
  handles backfill via the Library window's
  `wand.and.stars` button + progress sheet.
- Same AFM gating as Phase 1 + 2 (availability check +
  `localChapterClassification` toggle reused for now — a
  separate "auto-classify genres" toggle is v1.1 if anyone
  wants finer control).

### Phase 2.5 — Post-OCR cleanup (shipped)

Shipped in commit `0e93526` (the PLANS doc wasn't updated to
reflect it at the time; corrected on 2026-05-12). On-device
counterpart to `ClaudePostProcessor` — same trigger gate
(`OCRTextQualityScorer`), same length floor, same guardrail
policy (`OCRChangeGuardrail`), same `ClaudePostProcessor.Result`
return shape. Only the model call differs: schema-guided AFM
`respond(instructions:prompt:)` against a `@Generable
CorrectedText` struct rather than an Anthropic round-trip.

Text-only. Vision-mode requests decline (return nil) rather
than silently downgrading, so callers that wanted vision-mode
cleanup on the hardest regions can route to Cloud Haiku
instead of accepting passages-only correction on something
that was flagged for vision specifically.

Wiring: new `PostOCRProcessor` protocol; `ClaudePostProcessor`
retroactively conforms via an empty extension;
`AppleFoundationModelPostProcessor` joins as a sibling impl;
`makePostProcessor(options:budget:)` factory prefers Cloud
(when configured) then falls back to AFM (when its toggle is on
and Apple Intelligence is available); the cascade's
`applyPostOCRCleanup` retyped to the protocol so the per-region
call site doesn't branch on which impl is active.

Settings: `LocalFeatures.localPostOCRCleanup` Bool (default
true), exposed in `AISettingsView` alongside the other Local
AI toggles. Local AI section visible in both Cloud and Private
modes — AFM picks up as a fallback whenever Cloud isn't
properly configured, closing the gap where a Cloud-mode user
without a key used to get no AI assistance at all.

9 smoke tests added on 2026-05-12 covering vision rejection
(with/without image), short-text rejection,
clean-text-above-threshold rejection, prompt composition,
`PostOCRProcessor` protocol conformance, and the verbatim-
except-JSON-clause prompt parity with the Cloud path. AFM
itself isn't mockable (the client wraps Apple's framework
directly); end-to-end behavior is verified by the Cloud-side
tests in `ClaudePostProcessorTests` since both impls share
every piece except the model call. 1036 tests pass total.

### Still pending

- **Phase 3 — TOC parsing**. Long-context structured extraction.
  AFM's 8K-token context is tight for full TOCs of long books;
  some chunking strategy needed. Deferred until we have Phase
  1+2 quality data on simpler shapes to inform whether the
  chunking complexity is worth it.

The previous Tier 8 placeholder (`S-Apple-Intelligence-Polish`) is
superseded by this entry now that the macOS 26 floor makes it a
first-class feature rather than a stretch.

### Why bother

The user's choice of Private mode is a privacy / cost / offline
preference, not a quality preference. Today that choice costs them
every Cloud-only feature. AFM is a 3B-class model — meaningfully
smaller than Claude Sonnet, but plausibly competitive on
classification-shaped tasks where output is short and structured.
For Private-mode users the comparison isn't AFM vs Cloud; it's AFM
vs nothing. Even moderate quality is a real win.

The shape that fits AFM best is **schema-guided classification**.
Several existing Cloud features map cleanly onto that shape:

- **Chapter classification**: input = chapter title (+ first
  paragraph), output = one EPUB 3 `epub:type` token from a closed
  enum. Bounded. Fast. Easy to A/B against Cloud Sonnet.
- **Metadata extraction**: input = front-matter pages, output =
  `Generable` struct with `title / author / year / publisher / isbn`.
  Probably AFM's strongest use case — small input, structured output,
  lots of training-data overlap with publication conventions.
- **Post-OCR cleanup**: input = (originalText, regionImage),
  output = (cleanedText, confidence). Quality uncertain on hardest
  regions (worn type, polytonic Greek); Cloud path stays as the
  high-quality option.

What AFM doesn't help with: vision tasks (page-OCR, hard-region OCR,
table extraction) where the model needs to read pixels — AFM is
text-only. Those Cloud features stay Cloud-only. Chat-with-book
already has a local backend (Ollama, Gemma 4 26B); AFM would be
worse for that use case.

### Scope: phased rollout

**Phase 1 — chapter classification (~1-1.5 days).** The clean
beachhead.

- `Sources/AI/AppleFoundationModelClient.swift` — actor wrapping
  `LanguageModelSession`. Ping / availability / structured-respond
  surface; mirrors the `OllamaClient` shape so future swaps are
  mechanical.
- `Sources/Pipeline/AppleFoundationModelClassifier.swift` —
  `@Generable enum EpubChapterType { case chapter, preface,
  foreword, … }`; per-chapter `respond(to:generating:)` call with
  the title + first paragraph. Conforms to the existing
  `SemanticClassifier` protocol so the pipeline picks between
  Cloud and Local based on Settings + availability.
- Settings → AI → Local AI: new toggle `localChapterClassification`
  (default on under Private mode when AFM is available); graceful
  fallback when `LanguageModelSession.availability != .available`
  (user disabled Apple Intelligence) — silent skip, no banner.
- Validation: hand-classify ~10 chapters as ground truth; compute
  AFM accuracy vs Cloud Sonnet vs Cloud Haiku. Ship if AFM lands
  within ~5% of Haiku.

**Phase 2 — metadata + cleanup (~2-3 days, opt-in).** Once Phase 1
ships and the client is proven:

- `AppleFoundationModelMetadataExtractor` — front-matter →
  `BookMetadata` `Generable` struct. Parallels
  `ClaudeMetadataExtractor`.
- `AppleFoundationModelPostProcessor` — per-region typo cleanup.
  Document the quality tradeoff ("Cloud Haiku is more accurate on
  worn / classical text") so users can opt back to Cloud where
  needed.
- `AppleFoundationModelCoherenceAnalyzer` — recurring-OCR-error
  detection across whole book. Long-context (whole-book digest);
  AFM's 8K-token window is tight, so probably needs chunking or a
  "skip on long books" fallback.

**Phase 3 — TOC parsing (defer).** Long-context structured
extraction. Hardest of the bunch. AFM might struggle vs Cloud
Sonnet's much larger window. Punt until Phase 1+2 validate AFM
at smaller scopes; revisit if there's demand.

### Architecture

```
Sources/AI/
└── AppleFoundationModelClient.swift  NEW — LanguageModelSession wrapper

Sources/Pipeline/
├── SemanticClassifier.swift          (existing protocol)
├── ClaudeChapterClassifier.swift     (existing — Cloud path)
└── AppleFoundationModelClassifier.swift  NEW — Local path
```

The pipeline's chapter-classification stage already abstracts behind
`SemanticClassifier`; adding a third backend (alongside Cloud +
no-op-fallback) is a constructor-injection change, not a refactor.

### Settings

- New `Local AI` section in Settings → AI, parallel to the existing
  `Cloud Features` section. Each entry mirrors a Cloud-mode toggle
  but routes through AFM when enabled.
- Defaults: under `processingMode == .privateLocal`, all
  Local-AI features default *on* when `LanguageModelSession.
  availability == .available`. Defaults to *off* otherwise.
- "Apple Intelligence isn't enabled" notice with a deep link to
  System Settings → Apple Intelligence when availability is
  `.unavailable(reason)`.

### Risks

- **macOS 26 minor-version churn**: Foundation Models is new in
  macOS 26.0; API may shift in 26.x point releases. The thin
  client wrapper isolates the blast radius — most code references
  `AppleFoundationModelClient`, not the framework directly.
- **AFM quality on non-English content**: weaker than English.
  For chapter titles (typically in the book's primary language)
  probably fine. For classical-script bodies (post-OCR cleanup)
  more uncertain — document as a known limitation; recommend
  Cloud for those users.
- **Apple Intelligence opt-in**: user must have it enabled in
  System Settings. Off by default for some setups (managed Macs,
  privacy-conscious users). Graceful fallback handles this.
- **Quality-floor regression**: enabling Local AI for a user who
  was happily on Cloud with high-accuracy settings would be a
  downgrade. Default Local-AI features under Private mode only —
  Cloud users keep their Cloud features.

### Effort

Phase 1 alone: ~1-1.5 days end-to-end:
- ~0.5 day: `AppleFoundationModelClient` + availability probe.
- ~0.5 day: `AppleFoundationModelClassifier` + `Generable` enum
  for `epub:type`.
- ~0.5 day: Settings UI + pipeline wiring + validation against
  hand-classified ground truth.

Phase 1+2 together: ~3-4 days. Phase 3 deferred.

### When to ship

Anytime; orthogonal to chat / library work. Strongest fit for
users who specifically chose Private mode (where the upside is
biggest) — gives them feature parity for the classification-
shaped tasks Cloud users have had since R-Conversion-Summary.

### Dependencies

- macOS 26+ — already targeted (`Package.swift` platform floor;
  matches the `macos-26-only` memory).
- User has enabled Apple Intelligence in System Settings —
  detected via `LanguageModelSession.availability`; graceful
  fallback when unavailable.
- Existing `SemanticClassifier` protocol in the pipeline (Phase 1)
  and `MetadataExtractor` / `OCRPostProcessor` / `CoherenceAnalyzer`
  protocols (Phase 2) — all already abstract over the Cloud impls,
  so the AFM impls slot in alongside.

---

## P-Cascade-Parallel — Bounded parallel pages in cascade mode

**Status**: not built. Today's cascade page-loop processes pages
serially in a single `for i in 0..<totalPages` body. Within one
page, Vision OCR and Surya layout already overlap via `async let`
([PDFToEPUBPipeline.swift:1978](Sources/Pipeline/PDFToEPUBPipeline.swift#L1978))
— that's [P-Vision-Concurrency](#p-vision-concurrency--overlap-vision-ocr-with-surya-layout)
shipped. Across pages, no parallelism in cascade mode. Only the
Cloud page-OCR path has the bounded `parallelPageOCRConcurrency`
TaskGroup at
[PDFToEPUBPipeline.swift:2301](Sources/Pipeline/PDFToEPUBPipeline.swift#L2301).

### Goal

Cut wall time on bulk Private-mode conversions by running 2–8
cascade pages concurrently. Realistic gains on a 300-page book:
- **No Surya** (born-digital, useHighAccuracyOCR off): ~2–3×
  speedup. Render + Vision + embedded-extract + Tesseract all
  parallelize cleanly across cores.
- **With Surya** (default): ~1.2–1.5× speedup. The Surya sidecar
  is a singleton Python process — parallel callers queue at it.
  Other steps still benefit; Surya stays the long pole.

Reuses the existing `cloudFeatures.parallelPageOCRConcurrency`
knob (already in Settings → AI → Throughput) — semantically it's
"pages in flight," same meaning across both cascade and
page-OCR modes.

### Approach

Three-phase plan.

**Phase A — Extract `processCascadePage(...)` helper**. Pull the
existing for-loop body's cascade branch (lines ~1875–2210 today)
into a `nonisolated` instance method on `PDFToEPUBPipeline` that
takes:
- `pageIndex: Int`
- `pdfURL: URL` (each task loads its own `LoadedPDF`; the
  periodic `pdf = try loader.load(pdfURL)` cache-drain pattern
  goes away because per-task documents have short lifetimes)
- The engines + config the body reads (most are `let` fields
  on `PDFToEPUBPipeline`; the per-conversion engines like
  `claudeOCREngine` / `claudePostProcessor` get passed
  explicitly)

Returns a packed `CascadePageOutcome` struct holding everything
the for-loop currently writes back to outer accumulators:
- `pageObservations: PageObservations`
- `verdict: EmbeddedTextQualityScorer.Verdict`
- `figures: [FigureExtractor.ExtractedFigure]`
- `tables: [(regionIndex: Int, rows: [[TableCell]])]`
- `qualityScore: EmbeddedTextQualityScorer.Score`
- `extractorDiagnostics: EmbeddedTextExtractor.Diagnostics`
- `correctionTrailEntries: [CorrectionTrail.Entry]`
- `layoutError: String?`
- `ocrError: String?`

Keep the existing serial for-loop calling the new helper; verify
tests still pass byte-for-byte. **Phase A is the bulk of the
refactor — the bounded TaskGroup in Phase B is small once the
helper exists.**

**Phase B — Bounded TaskGroup**. When
`options.cloudFeatures.parallelPageOCRConcurrency > 1` AND
cascade path (no `activePageEngine`), wrap the cascade-bound
page indices in a `withThrowingTaskGroup` with the existing
bounded-fan-out pattern (same shape as the page-OCR dispatch
at [PDFToEPUBPipeline.swift:2301](Sources/Pipeline/PDFToEPUBPipeline.swift#L2301)).
Pages with resume checkpoints stay on the fast-skip path;
page-OCR pages still defer to the existing post-loop dispatch.

Convert `pageResults: [PageObservations]` from an order-sensitive
array to a `pageResultsByIndex: [Int: PageObservations]` (same
pattern `pageOCRPendingByIndex` already uses for the Cloud path).
Sort at the post-loop assembly step.

**Phase C — Surya pool (deferred)**. The Python sidecar
singleton remains the bottleneck on Surya-heavy books. The
existing [P-Surya-Pool](#p-surya-pool--multiple-surya-sidecars-for-parallelism)
section covers the eventual fix — pool 2–4 Surya processes —
but it's separately scoped (memory budget, IPC complexity) and
not in P-Cascade-Parallel's critical path.

### State changes

- `pageResults` array → index-keyed dict, sorted at end
- `figureExtractionsByPage` / `tableExtractionsByKey` /
  `verdictsByPage` / `extractorDiagnostics` / `qualityScores` /
  `layoutErrors` / `ocrErrors` — already index-keyed, just need
  to populate from outcome bundle
- `correctionTrailEntries` — append-only; entries carry
  `pageIndex` so order isn't critical, but post-loop sort by
  page index keeps debug logs readable
- `pdf: LoadedPDF` outer-scope mutable var → goes away; each
  task loads its own. The periodic-reload memory-management
  pattern dissolves because per-task lifetimes are short.
- `progress?(...)` callback — needs `completedPages` to read
  monotonically; use an atomic counter incremented as
  outcomes complete (the `pageIndex` in the outcome lets the
  callback still surface "now processing page N" if desired)

### Risks

- **PDFKit per-task load cost**: re-parsing `LoadedPDF` per
  parallel task. On a 300-page book at concurrency=4, that's
  4 in-flight `PDFDocument` instances vs today's serial 1.
  Per-load cost is ~50ms; the total reparses are bounded by
  concurrency (4× peak), not page count.
- **Surya queue starvation**: parallel callers all wait on
  the same sidecar. Risk is acceptable today (sidecar's
  internal queue is bounded and well-behaved), but watch for
  timeouts on books that push concurrency × pages-pending
  past the sidecar's capacity.
- **Tesseract C-API thread-safety**: `TesseractOCREngine` uses
  the C API which is single-threaded per `TessBaseAPI` instance.
  Today's engine likely shares one instance; verify it's safe
  to call from N concurrent tasks or pool instances.
- **Memory pressure**: each in-flight task holds a rendered
  page image (~4 MB at 400 DPI), Surya layout regions, OCR
  observations, optionally cropped region images for Cloud
  cleanup. At concurrency=8 that's ~32 MB just for page images
  before Surya regions get accounted; manageable but worth a
  budget check.

### Effort

Honest estimate: **4–6 hours** of careful refactoring + testing,
likely across two sessions. Phase A alone is ~3 hours; Phase B
is ~1–2 hours once Phase A lands clean.

### Dependencies

- `ClaudeRateLimiter.shared` (already shipped) — protects
  Anthropic-side calls when N parallel pages hit cloud engines.
- `GeminiEmbeddingRateLimiter.shared` (already shipped) — same
  for Gemini.

### Sequencing

Behind near-term items but ahead of P-Surya-Pool (which only
matters once Cascade-Parallel exposes Surya as the bottleneck).
Earns priority when a real bulk-Private-mode workload makes
serial cascade conversion feel slow.

---

## C-Pipeline-File-Split — Carve `PDFToEPUBPipeline.swift` into per-concern files

**Status**: shipped 2026-05-18 across 7 commits. The 4582-line
monolith carved into seven sibling files via
`extension PDFToEPUBPipeline { … }`:

  - `PDFToEPUBPipeline.swift` (2367 lines) — Options + Progress
    + properties + init + the `convert(...)` orchestrator +
    shared helpers (regions, gap-fill, layout retry, etc.).
  - `PipelineCascadeLoop.swift` (380 lines) — `CascadePageOutcome`
    + `processCascadePage` (the per-page cascade body).
  - `PipelinePageOCRDispatch.swift` (962 lines) — Cloud page-OCR
    path: `PendingPageOCR`, sync TaskGroup dispatch
    (`runPageOCRPage`), Batches API dispatch
    (`dispatchPageOCRViaBatch` + `preparePageForBatch`),
    debug dump (`writeClaudePageResponses`), chapter decision
    log writer.
  - `PipelineAssembleBook.swift` (271 lines) — `AssembledBook` +
    `assembleBook` (reflow → Book via splitter dispatch +
    classification + coherence + metadata).
  - `PipelineEngineFactories.swift` (411 lines) — `makeXxx`
    Cloud + AFM-fallback engine factory family,
    `CapturedResponseStore`, `ClaudeEngines` bundle.
  - `PipelineWriteOutputs.swift` (175 lines) — `writeOutputs` +
    sibling `.txt`/`.md`/`.html`/`.docx`/`.searchable.pdf`
    emission + cover-from-page-0 rasterizer.
  - `PipelineReflow.swift` (131 lines) — `ReflowOutput` + the
    `reflow` static helper.
  - `PipelineStatsAggregation.swift` (102 lines) —
    `aggregateConversionStats` (per-page accumulators →
    `ConversionStats`).

Total ~50% reduction in the main file. Behavior-equivalent —
1353 tests pass byte-equivalent across every commit. Necessary
access-modifier widenings (`private` → default-internal on
engine fields + cascade helpers + page-OCR helpers + debug
writers + cover helpers) are local to the module since
sibling files can't see `private` declarations.

**Original status note (preserved for diff context)**: The
file was 4500+ lines and growing — every new feature layered
on (page-OCR provider choice, refusal-rate stats, bilingual
layout detection, rate-limit gating, Tesseract fallback
routing) had landed as additional methods on the same type
rather than being split out.

### Goal

Split the type across ~7 files using Swift extensions on
`PDFToEPUBPipeline`, with each file owning a defensible concern.
Same module (`Pipeline`), so `private` access stays intact across
files. Zero behavior change; pure carve-up.

### Proposed split

- **`PDFToEPUBPipeline.swift`** (~500 lines) — kept lean: the
  `Options` / `Progress` / `Stats` value types, stored
  properties + `init`, and the top-level `convert(...)`
  orchestrator.
- **`PipelineCascadeLoop.swift`** (~1000 lines) — the per-page
  cascade body and helpers. Naturally co-located with the
  `processCascadePage` helper that `P-Cascade-Parallel`
  Phase A will extract anyway.
- **`PipelinePageOCRDispatch.swift`** (~800 lines) — the
  Cloud page-OCR sync + batches paths, `PendingPageOCR`,
  `runPageOCRPage`, `dispatchPageOCRViaBatch`,
  `preparePageForBatch`, the local-fallback engine selector.
- **`PipelineReflow.swift`** (~600 lines) — the `reflow` static
  helper, `ReflowOutput`, paragraph reflow helpers, and the
  debug-log writer that consumes them.
- **`PipelineAssembleBook.swift`** (~400 lines) — `assembleBook`
  + `AssembledBook` + the splitter dispatch chain (PDF outline
  → TOC-driven → heuristic) + classification dispatch.
- **`PipelineWriteOutputs.swift`** (~200 lines) — `writeOutputs`
  + sibling-file emission (txt/md/html/docx/searchable-pdf).
- **`PipelineStatsAggregation.swift`** (~200 lines) — the
  per-page stats tally that produces `ConversionStats` at the
  end of `convert`.
- **`PipelineEngineFactories.swift`** (~300 lines) — the
  `makeXxxClaudeEngine` factory family + `makePostProcessor`
  + `makeCoherenceAnalyzer` + `makeMetadataExtractor` etc.
  Highly mechanical — all share the gating-policy comment block.

### Risks

- **Compile-time access checks shift slightly** — `private` in
  Swift is per-file by default; the extensions need to use
  `internal` or keep their helpers as the same-file extension
  inside the original file… or migrate `private` → `internal`
  with a `// internal because of file split, not public` doc
  note. Latter is the cleaner mass-rename. ~150 such methods
  to inspect.
- **Test breakage on `@testable`** — Pipeline tests use
  `@testable import Pipeline` so internal access is already
  granted. Should round-trip unchanged.
- **Diff noise risk** — git history for the original file
  gets harder to follow. Mitigation: do the split as a single
  commit per file (move only, no edits), so `git log --follow`
  threads cleanly.

### Approach

1. Land [P-Cascade-Parallel](#p-cascade-parallel--bounded-parallel-pages-in-cascade-mode)
   Phase A first. The `processCascadePage` extraction will
   already split out a chunk; doing the rest of the file-split
   at the same time amortizes the risk-of-breakage cost.
2. One commit per file: pure move + minimum access-modifier
   adjustments. No semantic edits in the split commit so a
   future reviewer can confirm correctness by diff alone.
3. Run the full test suite (1325+ tests) between each commit.
4. The `Sources/Pipeline/PDFToEPUBPipeline.swift` that remains
   should fit in a single readable scroll — the top-level
   API + the orchestrator function.

### Effort

~1 day. Mechanical move + access-modifier audit. The hard part
is the access-modifier sweep (`private` → `internal` where the
caller now lives in a sibling file); the file moves themselves
are 30 minutes.

### Sequencing

Behind P-Cascade-Parallel Phase A so the natural `processCascadePage`
extraction lands as part of the split. Worth doing the next time
someone needs to make a non-trivial pipeline change — the
multi-thousand-line file is the rate limiter on careful work.

---

## C-Multi-Stream-EPUB — Parallel-stream output for complex layouts (Glas, Loeb, Talmud)

**Status**: prompt + parser scaffolding shipped 2026-05-18; IR
expansion + EPUB round-trip pending. The Cloud page-OCR prompt
(both `ClaudePageOCREngine.baseSystemPrompt` and the Gemini
engine that shares it) teaches the model to emit
`<section data-stream="…">` wrappers for clearly parallel
streams (Glas-style multi-column body + sidebar + insets, Loeb
verso/recto, Talmud commentary). The parser
(`ClaudePageXHTMLParser`) recognizes these as block-level
no-ops — content paragraphs land in the flat block stream in
document order — and captures the distinct stream IDs into
`ClaudePageResult.detectedStreams` as a diagnostic. EPUB output
is still linearized.

### Goal

Emit a multi-stream EPUB for books whose layout genuinely demands
it (Derrida's *Glas*, Loeb Classical Library, Talmud editions,
art books with running marginalia). Each stream gets its own
spine sequence; cross-link metadata pairs facing passages so an
enhanced reader (or our own editor) can reconstruct parallel
display.

### Approach

Three-phase plan.

**Phase A — IR expansion**. Two viable shapes:

  1. **Block enum expansion**: add
     `.sectionBoundary(streamId: String?, isStart: Bool)`. Lowest
     friction at the IR level but requires touching ~120
     pattern-match sites across the pipeline (many will have
     `default:` clauses and absorb the new case silently;
     exhaustive switches need explicit clauses).
  2. **Per-block sidecar map**: a parallel
     `[BlockUUID: String]` carried alongside the `[Block]` array
     from page-OCR through to chapter assembly. No Block enum
     change, but the sidecar's index/UUID keying must survive
     `ChapterSplitter` and other transformations that reorder
     blocks. Brittle without UUIDs on Block (currently absent).

  Recommendation: (1). The pattern-match audit is mechanical and
  catches every site that needs to know about the new case; the
  sidecar approach is invisible and easier to drop on the floor.

**Phase B — EPUB writer round-trip**. `XHTMLWriter` recognizes
`.sectionBoundary` and emits `<section data-stream="…">` wrappers
around the contained block range. Cross-spine `data-facing` /
`data-stream-position` attributes link facing passages, building
on the bilingual-facing-page sidecar shape already shipped in
`P-Bilingual-FacingPage`.

**Phase C — Editor multi-stream view**. Editor pane that shows
each stream side-by-side, with synchronized scroll between
facing passages. Loads from the `data-stream` / `data-facing`
attributes in the saved EPUB. Most invasive piece; only worth
building once Phases A + B prove the data shape.

### State the parser captures today

`ClaudePageResult.detectedStreams: [String]` — distinct stream
IDs (sorted) observed via `<section data-stream="…">` on the
page. Empty for single-column pages. Surfaces today only via
the field on the result; Phase A wires it into the block-IR
so it flows downstream.

### Risks

- **False-positive multi-column detection**. The prompt
  addition tries to scope tightly ("clearly parallel text
  streams") but a model can still over-detect. Mitigation:
  measure detection rate on the corpus harness across single-
  and multi-column books before declaring done. Today's
  "linearized output regardless" posture is the safety net —
  even if the parser captures bogus stream IDs, the user-visible
  EPUB matches today's behavior.
- **Reading order ambiguity**. Multi-stream layouts like Glas
  have no canonical reading order. Phase B has to pick one for
  linear consumption; Phase C is the real fix. Until Phase C
  ships, users get one of the streams (the first emitted by
  the model) as the primary spine.

### Effort

- Phase A: ~1 day (the pattern-match audit is the bulk).
- Phase B: ~0.5 day (XHTMLWriter is straightforward).
- Phase C: 2-3 days (new editor pane, scroll sync).

### Sequencing

Behind P-Bilingual-FacingPage Phase (b) — that work has
overlapping shape (multi-spine EPUB with cross-link metadata)
and will inform the IR shape for this one. Earns priority when
a real Glas-style or Talmud-style book becomes a target.

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

**Status**: harness shipped 2026-05-12 — `humanist-cli
compare-corpus <dir>`. The original "hand-correct 5 pages × 10
books" plan was made obsolete when the user pointed out they
already have ~17 DRM-free O'Reilly tech books with publisher-
edited EPUBs sitting next to the source PDFs in iCloud Drive.
Those pro EPUBs *are* the ground truth — no hand-correction
needed.

### What shipped

- `Sources/EPUB/CorpusMetrics.swift` — `CorpusMetrics` value
  type (chapter / heading / paragraph / figure / table counts;
  inline `<em>` / `<strong>` / `<code>` / `<pre>` counts;
  `epub:type` labels per resource; word + character counts;
  unique-word set for Jaccard similarity).
  `CorpusMetricsExtractor.extract(from:)` opens an EPUB via
  `EPUBBook.open` and regex-extracts all of the above.
  `CorpusComparison` holds the per-book diff (actual vs
  reference) with `wordSetJaccard`, `characterCountRatio`,
  `retention(\.inlineCodeCount)` etc., and a positional
  `epubTypeAlignment()` helper for classification accuracy.
- `Sources/HumanistCLI/CompareCorpusCommand.swift` —
  `humanist-cli compare-corpus --dir <dir>` walks the directory,
  pairs PDFs with reference EPUBs by stem (with `_V\d+`
  suffix-stripping for publisher review-version filenames),
  converts each PDF via the full `PDFToEPUBPipeline`, extracts
  metrics from both, and emits either a text table or
  `--json`. `--limit N` for iteration; `--keep-output <dir>`
  to inspect converted EPUBs; `--private` to skip Cloud
  features.
- iCloud-safe directory enumeration (`contentsOfDirectory`
  with `options: []`, not `.skipsHiddenFiles`, per the
  existing memory).
- 16 new tests cover the regex extractors (count, body
  `epub:type`, XHTML stripping), `CorpusComparison.retention`
  semantics, and Jaccard similarity boundary cases.

### Baseline 2026-05-12 — full 17-book O'Reilly corpus, Private mode

| metric | value |
|---|---|
| median Jaccard word similarity | **0.71** |
| median character-count ratio | **0.94** |
| mean `<code>` retention | **0.00** |
| mean `<pre>` retention | **0.00** |
| mean `<em>` retention | **0.00** |
| mean `<strong>` retention | **0.00** |

Per-book Δcode spans (negative = code spans lost):

- narrative-leaning books: -12 to -758
- moderate code: -7,987 to -17,638
- code-heavy: -21,923 to **-38,097** (hands-on-ML cookbook)

Per-book Δparagraphs is *bimodal* and that's a finding by itself:

- narrative books **under-split** (Δpara -506 to -1043): we glom
  multi-line code into prose paragraphs.
- code-heavy books **over-split** (Δpara +298 to +1481): we treat
  every code line as a separate paragraph.

Two different reflow bugs depending on visual layout. See
**Q-Paragraph-Split-Consistency** below.

Char ratio drops as low as 0.79-0.80 in code-heavy books
(`machinelearningwithpythoncookbook`, `learninglangchain`).
That's ~20% of characters lost — Vision OCR on small monospace
glyphs is dropping content. Plausibly mitigated by Cloud OCR
or by Q-Code-Preservation's detection step.

Median Jaccard 0.71 on the full corpus vs 0.82 on the first 3
books — the corpus harness was originally tuned on three of
the most narrative-leaning books in the set; the code-heavy
majority pulls the median down. Worth re-running with Cloud
mode (`useClaudePageOCR` enabled) to get a Cloud baseline; the
harness's current `convert()` hardcodes `useClaudePageOCR:
false` (see "Harness limitations" below).

The 0% inline-tag retention is the most-useful single finding —
it elevates **Q-Code-Preservation** from a hypothetical concern
to a measured Tier 1 gap with concrete numbers. See the
expanded entry under Q-Hard-Captures.

Three more findings the harness surfaced beyond the original
umbrella, each promoted to its own Q-* entry:

- **Q-Callout-Boxes** (new): publisher emits 19+ `<aside
  epub:type="note">` per book for tip/note/warning sidebars;
  we emit 0. They come through as ordinary paragraphs at the
  wrong reading order.
- **Q-Chapter-Vocab-Expand** (new): publisher uses `part`,
  `sidebar`, `colophon`, `dedication`, `copyright-page`,
  `afterword`, `titlepage`, `toc`, `index`; our AFM
  classifier emits only `chapter` / `frontmatter` /
  `preface` / etc. — a much smaller `@Generable` enum than
  real-world books need.
- **Q-Chapter-Over-Split** (new): 41 chapters in our output
  for `hands-onlargelanguagemodels` vs 25 in the reference.
  ChapterSplitter triggers on something the publisher
  treats as a heading inside a chapter rather than a chapter
  boundary.

### Harness limitations to fix

- `CompareCorpusCommand.convert(...)` hardcodes
  `useClaudePageOCR: false`. To get a Cloud-mode baseline
  (which is what most users actually run), the harness needs
  a `--claude-page-ocr` flag that passes through. Trivial
  addition; do alongside the next Cloud-baseline run.
- Convert isn't parallel — 17 books sequentially is ~30-60
  minutes wall-clock. Could TaskGroup over books with a low
  concurrency cap (2-3) since each book's pipeline is
  already parallel internally. Defer until iteration speed
  is the bottleneck.

### Corpus storage convention

The user's corpus lives at `/Users/tim/Library/Mobile
Documents/com~apple~CloudDocs/Documents/Documents - Bird/Books/
O'Reilly AI and ML /` (note trailing space in folder name) —
flat directory, source PDFs + reference EPUBs paired by
filename stem. **Not shipped in the repo**: these are
copyrighted publisher EPUBs, fair-use as personal regression
fixtures but can't be distributed. Future expansion can mix
in tiny hand-redacted single-page excerpts at
`Tests/Fixtures/HardCaptures/` for specific heuristic edge
cases.

### Why this matters going forward

Every future Q-* item now has a measurable acceptance test —
"the metric improves on the corpus" instead of "looks better
to me." Q-Italic-Skip, Q-Vision-Backfill-Batch,
Q-Widow-Footnote-Guard, and any future heuristic change can
A/B'd against the harness before merge.

---

## U-HIG-Pass — Mac HIG / Liquid Glass conformance

Audit umbrella that pulls Humanist closer to Apple's macOS Human
Interface Guidelines and the macOS 26 Liquid Glass design system.
The app is already a SwiftUI native-Mac app with the right menu-bar
posture, real toolbars on the editor, and a proper Settings scene —
but several surfaces drift from HIG (icon-only buttons with no
VoiceOver labels, the Library window using an in-content "filter
bar" rather than `.toolbar`, custom search capsule instead of
`.searchable`, opaque backgrounds that block the floating-glass
treatment macOS 26 applies automatically).

Reference sources are recorded in the user's memory file
`reference_mac_uiux_sources.md`: Apple HIG component pages
(`toolbars`, `sidebars`, `menus-and-actions`, `windows`,
`settings`, `foundations/accessibility`), WWDC25 #310 "Build an
AppKit app with the new design" + "Adopting Liquid Glass" docs,
Mario Guzman's *Macintosh Checklist*, and usagimaru's *macOS
Settings Window Guidelines*.

Each sub-item is independently scoped — take or skip without
affecting the others. Sequencing is intentionally loose; the
audit is polish work, not a feature gate.

### U-HIG-Pass-A11y + U-HIG-Pass-Keyboard-Focus — shipped 2026-05-12

Shipped together since both audited the same icon-only-button
sites. Primary-surface coverage:

- **Library window toolbar** (`.navigation` sidebar toggle +
  `.primaryAction` group of language, bulk-edit, import, index,
  chat): `.accessibilityLabel` mirroring each `.help` string.
- **Editor toolbar pane toggles**: already accessible via
  `Label("Show PDF", systemImage:)` — Label's text doubles as
  the VoiceOver name. Documented this in-place so future
  readers don't add redundant `.accessibilityLabel` modifiers.
- **Editor PDF-pane toolbar** (Prev / Next / Zoom Out / Zoom In
  / Fit Page): bare `Image(systemName:)` buttons → all labeled.
- **Editor chat-pane header** (rebuild index, clear chat):
  labeled.
- **Source + WYSIWYG formatting toolbars** (~22 buttons via
  shared `iconButton(...)` helper): added one
  `.accessibilityLabel(label)` line in each helper, covering
  every formatting button at once.
- **Chat panes** (long-form toggle, retrieval-detail toggle,
  export, clear, rebuild federated index in library chat):
  labeled.
- **Chat input** Send button: labeled, with new `.help("Send
  (⌘Return)")` tooltip too.
- **Queue rows** in launcher + queue window: status icon
  marked `.accessibilityHidden(true)` (the adjacent status
  text is the description); remove button labeled.
- **DropZone**: `.accessibilityElement(.ignore)` to consolidate
  the decorative dashed-border + icon + label texts into one
  VO element, with a custom `.accessibilityLabel` /
  `.accessibilityHint` that explains the drag-drop affordance
  and points keyboard users at the "Choose Files…" button as
  the equivalent.

**Keyboard focus**: SwiftUI's `Button` is keyboard-focusable
by default — ThemeRow (`.buttonStyle(.plain)`), queue row
action chips, and library filter toolbar buttons all
participate in Tab navigation without further intervention.
The Library search field that previously needed
`@FocusState` is now `.searchable` (system-provided focus +
⌘F binding). The DropZone is non-interactive (drag-only)
and intentionally not focusable; the "Choose Files or
Folder…" button below it is the keyboard equivalent.

Build clean; 1036 tests pass.

### U-HIG-Pass-Toolbar-Library + U-HIG-Pass-Searchable — shipped 2026-05-12

Shipped together since both refactored the same Library filter
bar. The custom in-content `filterBar` `HStack` is gone;
`LibraryWindowView.toolbarContent` is now a real `.toolbar`
with:
- `.navigation` placement: collections sidebar toggle
  (leading-edge view-toggle convention)
- `.primaryAction` placement: language picker, bulk-edit
  (always present, disabled when selection empty so the click
  target stays discoverable), import, index menu, chat toggle

The custom capsule search field is replaced by
`.searchable(text:$searchQuery, placement: .toolbar, prompt:
"Search title or author")`. Lands in the titlebar natively,
gets the system clear button, ⌘F binding, and macOS 26 Liquid
Glass treatment. The `@FocusState searchFieldFocused` and the
hidden zero-size ⌘F overlay both went away.

The "N of M · K selected" count moved out of the content into
`.navigationSubtitle` via a new `librarySubtitle` computed —
matches the editor window's title + status posture and frees
the toolbar of status text.

Build clean; 1036 tests pass.

### U-HIG-Pass-LiquidGlass-Edges — shipped 2026-05-12

Smaller than the umbrella implied — Tier 2's Library refactor
already removed the only Divider that was competing with a
floating toolbar (the filter-bar separator). What remained was
the redundant root-VStack background paint in
`ContentView.body`.

- **Launcher**: removed
  `.background(Color(nsColor: .windowBackgroundColor))` from
  the root VStack. The window already paints that color, and
  the redundant paint would block macOS 26 Liquid Glass if
  U-HIG-Launcher-Toolbar later promotes `ModeStrip` into a
  real `.toolbar`. `ModeStrip` itself already uses
  `.background(.bar)` — the system material that adapts to
  Liquid Glass automatically.
- **Library**: nothing to do — Tier 2 removed the filter-bar
  Divider, and the window has no other competing backgrounds.
  Real `.toolbar` now picks up Liquid Glass automatically.
- **Editor**: pane-header backgrounds (`.windowBackgroundColor`)
  and `.underPageBackgroundColor` on the PDF viewer stay. These
  are internal chrome *inside* each pane, not at the window
  root, so they don't compete with the toolbar's glass
  treatment. The `paneHeader` Divider sits below the pane
  header (intra-pane separator), not below the window toolbar
  — keep.

The `ModeStrip` Divider in the launcher stays for now: ModeStrip
is the launcher's de facto status header (not yet a real
toolbar), and the Divider tells the eye where the chrome ends.
When U-HIG-Launcher-Toolbar lands, ModeStrip can become a
`.toolbar` and the Divider can drop alongside.

### U-HIG-Pass-About-Credits — Ship `Credits.rtf`

The About box currently shows whatever default text macOS
synthesizes from the bundle's `CFBundleShortVersionString`.
Adding `BundleAssets/Credits.rtf` (Surya, Tesseract, CodeMirror,
epubcheck, Apple Vision, NaturalLanguage, etc.) wires it
automatically — macOS picks up `Credits.rtf` from the bundle's
Copy Bundle Resources phase. ~30 min. Cheap win.

### U-HIG-Pass-Editor-Toolbar-Labels — not advisable (skipped 2026-05-12)

The original entry proposed moving the five pane toggles out of
`.navigation` placement so labels would render alongside the
icons. On re-review, this is wrong: `.navigation` placement
rendering icon-only is the intentional macOS convention for view
toggles on the leading edge. Mail, Notes, Pages, Xcode, and
Finder all use icon-only leading-edge toggles for sidebar /
inspector visibility — moving the editor's pane toggles to
`.automatic` would produce five labeled "Show X" buttons
crowding the title, which is *less* HIG-aligned, not more.

The three `.primaryAction` items (Save / Original menu / Reveal
in Finder) already use `Label(_:systemImage:)` and render
icon + label by default. No change needed.

Tooltips on the pane toggles (`.help("Toggle the PDF source pane
(⌘1)")` etc.) remain useful — they're the discoverability hook
for icon-only buttons. Accessibility labels for VoiceOver get
added in U-HIG-Pass-A11y.

MACUX.md's "icon + label is the macOS default" note applies to
`.primaryAction` items, not navigation toggles. Tightening the
MACUX entry is a follow-up if the distinction keeps tripping
future audits.

### Out of scope for this pass (discuss separately)

- ~~**U-HIG-Launcher-Toolbar**~~ shipped 2026-05-12 via
  Option β (compact toolbar with grouped menus). The launcher
  is now drop-zone + queue + Choose Files CTA + a compact
  Per-job-overrides disclosure; all per-job options live in
  toolbar menus.

  Toolbar layout:
  - `.principal`: `ModeBadge` — compact mode chip (Private /
    Cloud / Cloud-setup-needed-orange) that opens Settings → AI
    on click. Replaces the in-content `ModeStrip`. Misconfig
    state (no API key, or every Cloud feature off) tints the
    badge orange so cloud-mode users still see the warning
    at a glance even though the detail line went away.
  - `.primaryAction` group: **OCR Engine** Picker menu, **Languages**
    menu, **Outputs** menu, plus conditional Show Queue /
    Pause/Resume / Cancel All buttons.

  Real UX simplification: the three mutually-exclusive
  Cloud-OCR checkboxes (Claude OCR / Early Print / Manuscript)
  plus the redundantly-combinable Surya OCR toggle collapsed
  into one 5-way Picker (`LauncherOCREngine`: auto / surya /
  claudeTypeset / earlyPrint / manuscript). The Picker's
  menu label shows the currently-selected engine inline
  (including sub-pick: "Claude — Early Print (Blackletter)")
  so the user reads their setting without opening the menu.
  Sub-pickers (typeface, hand) appear inside the OCR Engine
  menu only when the parent mode is selected.

  Surviving overrides (Force Private, Force OCR, Force OCR
  pages, Output suffix) moved into a single `Per-job overrides`
  disclosure at the bottom of the content area — collapsed
  by default. Save log toggle moved into the Outputs menu
  alongside the sibling-format toggles.

  Files: ContentView.swift shrank from 1119 → 1067 lines
  net (added ~300 lines of toolbar / menus / overrides, removed
  ~358 lines of legacy optionsBlock / bottomBar /
  languageMenu / tesseractStatusBadge / advancedDisclosure /
  ModeStrip). The launcher now picks up macOS 26 Liquid Glass
  on the toolbar automatically.
- **U-HIG-Help-Book** — Apple Help Book + `MDItemKeywords`.
  Earns priority alongside P10 distribution, not before.
- ~~**U-HIG-Settings-Audit**~~ small fix-ups shipped
  2026-05-12. The density-imbalance question (AISettingsView
  is 844 lines vs EditorSettingsView's 125 — 6.7×) is real
  but is a UI-split decision deferred to a separate item:
  **U-HIG-AI-Settings-Split** below.

  Confirmed clean:
  - All four panes use `.formStyle(.grouped)` + radio /
    checkbox / picker controls — no toggle switches, no
    Save / Cancel / Apply buttons. (The "Save aliases"
    button in AISettingsView is a legitimate TextEditor
    commit, not a Settings-modeless violation.)
  - SettingsRoot frames 540×520, each `.tabItem` carries
    both icon and label.
  - Tab order Editor → Conversion → AI → Appearance reads
    "most-used first" rather than "general first," which
    is a defensible choice for an editor-centric app.

  Fixed:
  - AI pane's `.frame(minHeight: 420)` was inconsistent
    with Editor + Conversion's `460`. Bumped to 460 so the
    Settings window doesn't shrink when the user switches
    to the AI tab in Private mode (where the AI pane's
    intrinsic content is shorter).
  - Appearance pane was missing `.frame(width:)` and
    `.frame(minHeight:)` entirely, and used `.padding()`
    instead of `.padding(.vertical)`. Brought into line
    with the other three so content alignment + window
    bounds stay stable across tab switches.

### U-HIG-AI-Settings-Split — shipped 2026-05-12

Split out a separate Chat pane. Result: 5 tabs (Editor /
Conversion / AI / Chat / Appearance). Each pane is now under
~400 lines.

**AI pane** kept the conversion-pipeline AI sections:
Processing Mode, Anthropic API Key, Cloud Features, Cost Cap,
Local AI features for conversion (chapter classification,
metadata, coherence, post-OCR cleanup), Restore Defaults.
Down from 848 lines → 227.

**Chat pane** (new `ChatSettingsView.swift`) carries the book-
and library-chat sections: Book Chat backend selector (Cloud
Haiku / Cloud Sonnet / Local Ollama), Chat Retrieval
(BM25 / embedding / hybrid), structural / entity boost
toggles, Advanced retrieval tunables (RRF k, Top-K, max para
chars), Alias dictionary, embedding-backend chooser (Apple
NLEmbedding / Ollama / Voyage / Gemini) with per-backend key
management and Test Connection buttons, embeddings-cache
clear. 624 lines, self-contained — no shared view-model with
AI pane (each side uses its own `@AppStorage` properties and
Keychain stores).

Tab order is "most-used first" rather than "general first":
Editor (the app's primary surface) → Conversion (per-book
options) → AI (conversion AI) → Chat (chat AI) → Appearance.
AI and Chat sit adjacent so users who want to configure one
typically open the other right after.

`SettingsTab.chat` added to the persisted enum; existing
`humanist.settings.selectedTab` values still decode (the
default-fallback path catches unknown values and returns
`.editor`). 1036 tests pass.
- **U-HIG-LiquidGlass-Inspect** — full Xcode-26 pass with
  `NSGlassEffectContainerView`, `NSSplitViewItemAccessoryViewController`
  for editor pane headers, `NSView.LayoutRegion` for corner
  concentricity. Build once Xcode 26 is the floor *and*
  the above subtractive items have landed.

### Effort

The seven recommended sub-items sum to ~4.5 days of focused
work, mostly subtractive or annotation passes. None block
other PLANS.md items; sequence opportunistically.

---

# Tier 8: Stretch / speculative

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

### Q-Hard-Captures — Quality gaps on hard-to-read elements

Umbrella for user-reported quality gaps that fall between the
existing OCR cascade's seams. Surfaced 2026-05-12 from real
conversion experience. Each sub-item is independently shippable
and ordered by impact-per-effort.

#### Q-Italic-Skip — shipped 2026-05-12 (`7db9534`)

Two complementary gates so italicized foreign terms stop
getting "corrected" to English typos:

1. `correctedRun` in `PDFToEPUBPipeline` skips single-run
   blocks outright when the run carries `isItalic = true`.
   Catches the Claude-OCR'd path where italics arrive as
   proper run-level metadata.
2. `correctionFor` in `DictionaryCorrector` gained Guard 6 —
   cross-language validity check. Before applying any
   correction in the active language, validate the original
   word against every other supported European-language
   dictionary that's *installed* on this machine. Valid in
   another language → skip (safer to assume foreign term).
   Catches Vision / Tesseract paths that don't emit italics
   as separate runs at all.

Important implementation detail caught during testing:
`NSSpellChecker.checkSpelling(of:language:…)` silently
behaves permissively when called against an uninstalled
language (e.g. `ca`, `pt` weren't in availableLanguages on
the dev machine), so the cross-language guard had to filter
`supportedLanguages` against `checker.availableLanguages`
before iterating — otherwise it would have refused
legitimate corrections.

2 new tests cover the positive case ("vita" validates in
another supported language) and negative case (random
gibberish doesn't validate anywhere).

#### Q-Vision-Backfill-Batch — shipped 2026-05-12

Closed the parity gap. After the batch JSONL is walked, a
post-pass identifies pages whose result was `.refused`,
`.errored`, `.canceled`, `.expired`, or `.succeeded` with an
empty parse, and re-OCRs each via Vision. Renders the page
with `PDFRenderer(dpi: options.dpi)`, calls
`visionEngine.recognize`, reflows the observations via
`ParagraphReflow().reflow`, and replaces the matching
`PendingPageOCR` slot with `usedLocalFallback: true`.

Sequential per-page rather than parallel — 10% of 500 pages
refusing is 50 Vision calls at ~1s each, acceptable for the
edge case; can parallelize later if real bulk users complain.
Vision failure on top of that leaves the page blank (same
posture as the sync path's nested catch).

#### Q-Refused-Fallback-Surface — shipped 2026-05-12

`ConversionStats` gains `pagesUsingVisionFallback: Int`
(default 0, Codable-round-trip with optional decode so older
queue rows stay parseable). The `convert()` epilogue counts
pages with `usedLocalFallback == true` from
`pageOCRPendingByIndex` and threads the value through to
`ConversionStats.make(...)`.

`summary` appends "· N page(s) fell back to Vision" when
non-zero so the suffix shows up everywhere the summary
renders (queue row status line, queue-window status cell).
The launcher's `statsTooltip` (hover detail) gains a
dedicated line spelling out the cause: "Vision fallback —
N pages (Claude refused or errored; Vision OCR'd them
locally instead of leaving them blank)".

5 new tests cover the singular/plural summary forms, the
zero-fallback no-suffix case, the Codable round-trip, and
the legacy-JSON-without-the-field decode-with-zero
invariant.

#### Q-Code-Preservation (Tier 1, newly elevated 2026-05-12)

Surfaced by the corpus harness's first mini-run + full 17-book
run: we emit **0% of the `<code>` and `<pre>` tags** the
publisher EPUBs have. Inline code (function names, file paths,
shell commands) and code blocks (multi-line snippets) come
through as plain prose with whatever Vision / Tesseract made of
the monospace glyphs. For technical content, that loss is the
single biggest quality gap measurable today.

**Concrete numbers from the full corpus run**:

- 17 books, mean `<code>` retention 0.00
- Per-book Δcode spans range from -12 (least code-heavy) to
  **-38,097** (`hands-onmachinelearningwithscikit-learn`, the
  big O'Reilly ML reference)
- Cumulative `<code>` loss across all 17 ≈ 200,000+ spans

Two pieces missing in the document IR:

- `InlineRun` carries `isItalic` + `isBold` but **no
  `isCode` / `isMonospace`**.
- `Block` enum has `heading / paragraph / anchor / figure /
  table` but **no `.code` / `.preformatted`** variant. Multi-
  line code blocks get reflowed into prose by
  `ParagraphReflow`.

Two-tier fix:

1. **IR plumbing**: add `isCode` to `InlineRun`; add
   `.code(language:lines:)` to `Block`. Update XHTMLWriter
   to emit `<code>` / `<pre>` accordingly. Update Markdown
   + text + DOCX + HTML sibling writers to honor the new
   block kind. ~1 day, mostly mechanical.
2. **Detection**: where does the signal come from?
   - **Claude page OCR** (Sonnet / Opus, current `useClaudePageOCR`):
     simplest path is to instruct the prompt to wrap inline
     code in `<code>` and code blocks in `<pre><code>`.
     Sonnet handles this reliably when prompted. ~½ day.
   - **Tesseract**: per-word font flags include monospace
     when the model has been trained for it. Default
     tessdata doesn't tag font; would need a font-class
     adapter. Defer.
   - **Vision**: no font information; can't detect
     monospace from the API. Fallback heuristic: regions
     that span column position 0 in a fixed-width font on
     a colored background often signal code, but this is
     fragile. Defer.

A pragmatic v1: ship the IR plumbing + Claude page OCR
prompt-side detection. Tech-book users who turn Claude OCR
on get full `<code>` / `<pre>` retention; users on
Vision-only Private mode see no regression (we emit nothing
either way). Measurement: re-run the corpus harness after
the change; `<code>` retention should climb from 0 to
~0.8-0.95 on Cloud-mode runs.

Total effort: ~1.5 days for v1.

#### Q-Paragraph-Split-Consistency (Tier 1, surfaced 2026-05-12)

The corpus harness revealed `ParagraphReflow` is **bimodally
wrong** depending on the visual layout of code in the source:

- Narrative-leaning books: Δpara -506 to -1043 — multi-line code
  blocks get *under-split*, glomming code lines and the prose
  paragraph after into one giant block (the `conda create…` /
  `pip install…` example pulled out of the
  `hands-onlargelanguagemodels` conversion).
- Code-heavy books: Δpara +298 to +1481 — code blocks get
  *over-split*, with each code line emitted as its own
  paragraph. Reading order is mostly correct but tag structure
  is wrong.

Both bugs share a root cause: reflow heuristic uses line
spacing + indentation to decide paragraph boundaries, but
code blocks have unusual spacing and indentation that
defeats the heuristic in opposite directions depending on
the book's typesetting.

Likely fix path: Q-Code-Preservation's detection step
identifies code regions; the reflow heuristic then *defers*
on those (don't reflow, don't split — emit each code-region's
lines as the single `Block.code` body). Both bugs disappear
as soon as code regions are correctly tagged.

Effort: largely subsumed by Q-Code-Preservation if that ships
first. Standalone if not: ~½ day to tune ParagraphReflow's
indentation-based split heuristic with corpus regression
testing.

#### Q-Callout-Boxes (Tier 2, surfaced 2026-05-12)

O'Reilly tech books emit ~10-30 `<aside epub:type="note">`
callout boxes per book — tip / note / warning / example
sidebars. The publisher EPUB for `hands-onlargelanguagemodels`
has 19 `<aside epub:type="note">`; our conversion emits 0.
The callout content comes through as a regular paragraph,
typically in the wrong reading order (next to whatever body
text was visually adjacent on the page).

Detection signal: callout boxes have a visual frame (colored
background, border, distinct typography). Surya's region
classifier doesn't currently have a "sidebar" category; both
the visual region detector and the Cloud OCR prompt could
gain one.

For a v1 fix, the simplest path is to instruct the Claude
page-OCR prompt to wrap detected callouts in
`<aside epub:type="note">` (or `tip` / `warning` per the
visual cue). Same prompt-side approach as Q-Code-Preservation
detection.

Effort: ~½ day prompt change + IR plumbing for the `.aside`
block kind.

#### Q-Chapter-Vocab-Expand (Tier 2, surfaced 2026-05-12)

Publisher EPUBs use a richer `epub:type` vocabulary than our
chapter classifier emits:

- Already in our enum: `chapter`, `preface`, `foreword`,
  `appendix`, `bibliography`, `glossary`, `acknowledgments`,
  `dedication`, `epilogue`.
- Found in the O'Reilly corpus but missing: `part`,
  `sidebar`, `colophon`, `copyright-page`, `afterword`,
  `titlepage`, `toc`, `index`.

Cloud + AFM classifiers both use the same `@Generable` enum
defined in `Sources/Pipeline/EpubChapterType.swift`.
Broadening it teaches both impls without per-engine work.

The risk in expanding the vocabulary is the classifier
becoming less reliable on small distinctions (afterword vs
epilogue, titlepage vs copyright-page). Mitigation: keep the
top-level labels broad and add precise sub-labels only where
the corpus shows a clear gain.

Effort: ~½ day enum expansion + regression test on the AFM
classifier (`AppleFoundationModelClassifierTests`).

#### Q-Chapter-Over-Split (Tier 2, surfaced 2026-05-12)

`hands-onlargelanguagemodels` has 25 chapters in the
reference, 41 in our conversion. ChapterSplitter triggers on
something the publisher treats as a heading inside a chapter
rather than a chapter boundary. Plausible cause: our heading-
level inference emits `<h1>` for what's structurally an
`<h2>` section heading.

Needs fixture capture from the over-split book + comparison
against the reference's chapter file boundaries. Likely the
fix is ChapterSplitter respecting heading-level >= 2 as
section breaks, not chapter breaks. ~1 day with the harness
as the regression metric.

#### Q-Widow-Footnote-Guard (Tier 2)

The header/footer classifier and the footnote heuristic on
small text regions both occasionally misclassify legitimate
1-2 line body fragments at page boundaries as chrome.

Two tightenings:
- **Header/footer**: require cross-page recurrence (a fragment
  that doesn't repeat near-verbatim on the previous or next
  page is body text, not chrome). The classifier already has
  a recurrence pass; the gate isn't tight enough.
- **Footnote**: require at least one of (a) clearly smaller
  font than surrounding body, (b) a horizontal-rule region
  above, (c) a leading footnote marker (digit / dagger /
  asterisk). 1-2 lines alone is insufficient.

Needs real fixtures to tune. ~1 day plus fixture capture.

#### Q-Inline-Math (Tier 3)

`.formula` regions get rastered as figures (correct for
display math). Inline math — `x^2`, fractions, ∫, ∑ — in
body text comes through as garbled UTF-8. The Cloud-OCR
prompts could be instructed to wrap inline math in
`<span class="math">…</span>` so a reader at minimum sees
the text variant cleanly. Full MathML rendering is a
separate larger lift. ~½ day for the prompt change + parser
recognition.

#### Q-Marginalia-Filter (Tier 3)

Library stamps, owner signatures, handwritten margin notes in
scanned books all get OCR'd as body text. No "is this in the
page margin?" gate today. A region-position classifier
(distance from the body bounding box exceeds N% of page
width or sits clearly outside the body column) would let us
flag regions as `.marginalia` and exclude them from body
reflow. ~1 day.

#### Q-Drop-Caps (Tier 3)

Drop caps at chapter starts get OCR'd as a separate region
from the rest of the first word ("T" + "he story begins…"
instead of "The story begins…"). Heuristic: a single
uppercase-letter region whose right edge adjoins a body
block whose first word starts with lowercase → merge the
two. ~1 day.

#### Out of scope for this umbrella (separate items)

- **Math notation full rendering** (MathML emission). Reader-
  side rendering across EPUB readers is patchy; emit text +
  the inline `<span>` wrapper from Q-Inline-Math and defer
  the renderer.
- **Mid-paragraph headings**. Real but rare; needs a
  representative fixture before designing a fix.
- **Two-column TOC with leader dots**. Often handled by
  the printed-TOC parser when Cloud is on; revisit if it
  becomes a recurring complaint.

#### Effort total

Tiers 1-3 sub-items combined: ~4-5 days. None blocks others;
sequence by which complaint surfaces next.

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
2. **E-Vision-Modes** — Manuscript mode (Claude Opus 4.7,
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
3. **R-Library-Chat-Plus** — workflow enhancements for the
   library chat surface: scope control (Chat with Selected,
   Collections), suggested follow-ups, long-form synthesis,
   citation export, conversation export, pinned passages, ask-
   each-book mode, and a few speculative items (knowledge graph,
   multi-model A/B). Tiers 1+2 are about 3 days end-to-end and
   cover the practical research-workflow surface; Tiers 3+4 are
   nice-to-haves to pick from based on actual friction.
4. **L-Foundation-Models Phase 2.5 + 3** — Phases 1 and 2 (mostly)
   shipped. The remaining Phase 2 piece is on-device post-OCR
   cleanup; needs a shared protocol over the per-region cleanup
   call site in `RegionCascade` (text-only mode only — AFM has no
   vision capability, so the Cloud path's vision-mode branch
   stays Cloud-only). Phase 3 — TOC parsing — remains deferred
   until quality data on the simpler shapes informs whether
   chunking complexity is worth it. Together: ~1-2 days.
5. **Distribution polish** — see `RELEASES.md`. Need a Developer
   ID Application certificate (Apple Developer Program, $99/yr),
   then notarization → DMG → GitHub Releases. ~3 days of work
   gated on the cert.
6. **P-Greek-Quality** — ground-truth measurement of Tesseract
   polytonic-Greek CER. Pure measurement task; only needs
   implementation work if CER comes back > 5%.
7. **Stretch / speculative items in Tier 8** if a specific need
   surfaces — custom footnote styles, audio output via
   `AVSpeechSynthesizer`. (Apple Foundation Models for chapter
   classification has graduated out of stretch into
   `L-Foundation-Models` above now that macOS 26 is the floor.)

Phase 9 (RTL / Hebrew / Syriac / Coptic) is deferred indefinitely
— corpus doesn't justify the bidi-rendering and per-script
accuracy lifts.
