# Humanist

Native macOS app (macOS 26+) that converts PDFs and text documents into well-formatted EPUB 3 files, with a full-featured editor for post-conversion cleanup. Aimed at academic books — polytonic Greek, Latin, mixed-script footnotes, printed tables of contents, figures with captions. Surya for layout analysis, Apple Vision + Tesseract for OCR, and optional Claude (Anthropic API) for the cases the local cascade can't handle on its own.

## Inputs

Drop any of the following onto the launcher window:

| Format | Path |
|---|---|
| `.pdf` | Full OCR pipeline — scan detection, layout analysis, cascade OCR, EPUB build |
| `.txt` `.md` `.rtf` | Text ingest — paragraph detection, heading + emphasis preservation, direct EPUB build |
| `.docx` `.doc` `.odt` `.html` | Attributed-text ingest — heading styles, bold/italic from font traits, direct EPUB build |
| Folder | Queues every supported file inside |

## What the PDF pipeline does

Each PDF job runs through:

- **Two-up scan detection** — facing-page scans get auto-split with a confirmation prompt.
- **Language auto-detect** — `NLLanguageRecognizer` samples body pages and overrides the picker when confident.
- **Pre-flight cost estimate** — Cloud-mode jobs show projected Claude calls + dollar cost before you click Convert.
- **Embedded-text trust scoring** — clean text layers pass through untouched; broken `ToUnicode`, mojibake, or language-mismatched layers trigger full re-OCR.
- **Per-region OCR cascade** — Vision → Surya → Tesseract → optional Claude Sonnet for hard regions, gated on a per-region quality scorer.
- **Whole-page Claude OCR** (optional, ~$0.04/page) — one Sonnet call per page returns structured XHTML directly; bypasses the per-region cascade. Adaptive routing skips Sonnet on pages that score as trusted embedded text.
- **Post-OCR Haiku cleanup** (optional) — fixes character-level errors (ligatures, missing diacritics, long-s) on low-quality regions. Text-only or multimodal (sends the region image alongside the OCR text).
- **Layout-aware reflow** — Surya classifies regions as text / heading / footnote / figure / table / caption; reflow respects the classification, repairs cross-page hyphenation, and normalizes typography (ligatures, dashes, smart quotes).
- **Figure extraction** — `.picture` and `.formula` regions raster-cropped into `OEBPS/images/`; cover-image detection for page-0 dominant figures.
- **Table extraction** — Surya `TableRecPredictor` (or Claude Sonnet under Cloud mode) with an X/Y heuristic fallback; emits proper `<table>` with `<thead>`/`<tbody>`/merged cells.
- **Footnote linking** — EPUB 3 popup notes: `<aside epub:type="footnote">` + `<a epub:type="noteref">`, so e-readers pop them up in place.
- **Printed-TOC parsing** (optional, one Haiku call) — extracts the printed table of contents into authoritative chapter titles and nav.xhtml entries.
- **Semantic chapter classification** (optional, one Haiku call per chapter) — labels each section (`preface`, `chapter`, `appendix`, `bibliography`, `index`, etc.) for EPUB semantic navigation.
- **Document coherence pass** (optional, one Haiku call) — identifies recurring OCR errors across all chapters and applies normalized replacements.
- **Metadata extraction** (optional, one Haiku call) — pulls title, author, year, publisher, and ISBN from the front matter; writes them to OPF `<dc:*>` fields.
- **Italic/bold preservation** — per-word font attributes from Tesseract, Vision flags, and typographic heuristics flow through the full cascade to the output XHTML.

## Outputs

Every conversion produces:

| File | Description |
|---|---|
| `<basename>.epub` | Primary output — EPUB 3 with full nav, figures, tables, footnotes |
| `<basename>.txt` | Plain-text sibling — flat paragraphs, footnotes in a per-chapter Notes section |
| `<basename>.md` | Markdown sibling — headings, GFM tables, `[^N]:` footnote definitions |
| `<basename>.html` | Self-contained HTML5 sibling — inline CSS, opens in any browser without unzipping |
| `<basename>.docx` | Microsoft Word OOXML — opens in Word, Pages, Google Docs |
| `<basename>.searchable.pdf` | Source PDF with an invisible OCR text overlay — Cmd+F searchable, no visual change |

The launcher splits sibling outputs into two toggles: **`.txt + .md`** (cheap, on by default) and **`.html + .docx`** (heavier, off by default). All siblings are regenerated whenever you save the EPUB in the editor. An optional **configurable output folder** (Settings → Conversion) routes each format into its own subfolder (`Books/`, `Text Files/`, `Markdown/`, `HTML/`, `Word Documents/`).

## Editor

Every produced EPUB opens in a five-pane editor:

| Pane | Key | Description |
|---|---|---|
| Original | ⌘1 | PDF source, synced to the source cursor via page anchors |
| Source | ⌘2 | XHTML markup in CodeMirror — formatting toolbar, find/replace, spell check |
| Preview | ⌘3 | Live rendered EPUB preview, auto-updates on save |
| WYSIWYG | ⌘4 | Contenteditable WebView rendered with the book's own CSS — formatting toolbar, syncs with Source on save |
| Chat | ⌘5 | Chat-with-book — BM25 retrieval picks relevant chapters as context; the configured backend answers with clickable chapter citations; transcript persists across sessions. Backends: **Cloud (Haiku)**, **Cloud (Sonnet)**, or **Local (Ollama)** for fully on-device chat (default Gemma 4 26B MoE) |

**Source pane** features:
- Formatting toolbar: Bold, Italic, Code, Sup/Sub, H1–H3, Blockquote, Lists, HR, Link, Language tag, Smart Quotes
- Format / Insert / Edit / View menus with full keyboard shortcut coverage
- Find in all files (cross-chapter search + replace, ⇧⌘F)
- Spell check with per-book alternatives dictionary
- Go to Line, Special Character picker

**Chapter management:**
- Split / Merge / Move Up / Move Down / Rename Chapter (with automatic internal link rewriting)
- Drag-and-drop reorder in the sidebar
- Regenerate Table of Contents
- Footnote Manager — scans for unlinked `<sup>N</sup>` callsites, matches against end-of-chapter definitions, applies EPUB 3 noteref/aside markup
- Chapter Manager — spine overview with `epub:type` picker and reorder controls

**Other editor tools:**
- Re-OCR Current Page (single-page re-run with the engine of your choice)
- Re-OCR All Pages (bulk re-run; preserves manual edits between pages)
- Correction Trail — review / apply / revert every Haiku post-OCR suggestion
- Validate EPUB (`epubcheck` wrapper)
- Customize Style (per-book font, size, and theme stored in `book.css`)
- Equalize Panes / visible pane dividers
- Save-on-close dialog when the document has unsaved changes

## File Tools

A **File Tools** menu provides four file-system utilities that work without opening any editor window:

- **PDF Join** — concatenate N PDFs into one
- **PDF Split** — extract page ranges into separate PDFs
- **EPUB Join** — merge N EPUBs, each source under its own subdirectory
- **EPUB Split** — split one EPUB into chapter-range parts

## Command-line interface

A second executable target — `humanist-cli` — exposes the same Pipeline and EPUB modules as a scriptable shell tool. Same engines, same conversion quality, no GUI surface.

```sh
swift build --product humanist-cli -c release
cp .build/release/humanist-cli ~/.local/bin/

humanist-cli convert paper.pdf                     # default → paper.epub
humanist-cli convert paper.pdf -f md               # markdown only
humanist-cli convert book.pdf -f epub,md,html,docx -o ./out
humanist-cli convert paper.docx -f md              # DOCX → MD, bypasses OCR
humanist-cli compare old.epub new.epub             # paragraph-level diff
humanist-cli validate book.epub                    # epubcheck wrapper
```

Per-feature Cloud toggles are individual (`--no-claude-tables`, `--no-coherence-pass`, etc.); `--private` forces all off. API key reads from `$ANTHROPIC_API_KEY`. JSON output mode (`--json`) for CI / scripts. Full reference at [Sources/HumanistCLI/README.md](Sources/HumanistCLI/README.md).

## Setup wizards

External dependencies are installed by the user on first launch via in-app wizards rather than bundled in the .app — keeps the bundle tiny (~14 MB), keeps notarization simple, and lets users opt out of any dependency they don't need:

- **Surya** (~1 GB) — layout analysis. Without it the cascade falls back to Vision-only OCR with no region classification. Banner appears on the launcher when not installed; wizard at *Welcome → Set up Surya…* uses `uv tool install surya-ocr`.
- **Tesseract** (~150 MB) — classical-script OCR (polytonic Greek, Latin, Hebrew). The "Tesseract not installed" badge is contextual — only shows when your language selection would benefit. Wizard installs via `brew install tesseract tesseract-lang`.
- **Ollama + Gemma 4 26B MoE** (~18 GB) — local chat backend. Optional; the chat pane defaults to Cloud (Haiku). Wizard at *Settings → AI → Set Up Local Chat…* walks through `ollama pull gemma4:26b`.

Each wizard mirrors the same three-step flow: install the package manager (Homebrew / uv / Ollama), install the dependency, verify. Live streamed install output, contextual error messages, and a "Skip" option that's always honored.

## Privacy posture

**Private mode is the default.** Everything runs locally — Vision, Surya, Tesseract — and no data leaves your machine. Cloud features only run when you enable them in Settings (⌘,) and provide an Anthropic API key. Per-feature toggles let you opt in one at a time; a per-book call cap bounds the worst-case cost.

## Build and run

```sh
Scripts/run-app.sh          # release build + assemble .app + sign + open
swift test                  # unit tests
```

`Scripts/run-app.sh` is the only supported launch path. `swift run` / `swift build` produce a bare binary without the bundled `Resources/` directory — the editor's CodeMirror source pane and the Surya layout sidecar won't load.

### Cloud-mode setup (optional)

1. Get an Anthropic API key from <https://console.anthropic.com>.
2. Open Settings (⌘,) → **AI → Anthropic API Key** and paste the key. Stored in the macOS Keychain.
3. Switch **Processing Mode** to Cloud and enable the features you want (hard-region OCR, table extraction, post-OCR cleanup, coherence pass, metadata extraction, TOC parsing, semantic classification).
4. Drop a PDF. The queue row shows a pre-flight cost estimate before the conversion starts.

Typical cost is pennies to a few dollars per book depending on which features are on and whether you use the whole-page Sonnet path.

## Source layout

```
ocr/
├── Package.swift
├── Sources/
│   ├── Humanist/                       SwiftUI app — launcher, editor, settings, library, file tools, setup wizards
│   │   └── Editor/Chat/                Chat-with-book view model + BM25 keyword index
│   ├── HumanistCLI/                    `humanist-cli` executable — convert/compare/validate from the shell
│   ├── Document/                       Canonical IR — Book / Chapter / Block / InlineRun / Footnote
│   ├── PDFIngest/                      PDFKit rendering, embedded-text scoring, two-up detection, language profiler
│   ├── OCR/                            OCREngine protocol — Vision, Tesseract, embedded-text gap-filler
│   ├── Layout/                         Surya sidecar bridge + region classification
│   ├── Pipeline/                       Orchestration: source → cascade → reflow → chapters → EPUB + siblings + DOCX
│   ├── EPUB/                           Book IR → EPUB 3 zipfile; XHTML / nav / OPF writers; in-memory editor model; differ + validator
│   └── AI/                             Anthropic API client, Batches API client, Ollama client, models, settings, key store
├── Tests/                              ~400 tests across all modules
├── Resources/
│   └── codemirror/                     Vendored CodeMirror 5 for the editor's source pane
├── Sidecars/
│   └── layout/sidecar.py               Surya layout + table model, Python via uv
├── BundleAssets/
│   ├── Info.plist
│   └── Humanist.entitlements
└── Scripts/
    ├── build-app.sh                    swift build + assemble .app + sign
    ├── run-app.sh                      build + open
    └── build-icon.sh
```

### Per-EPUB sidecars

Humanist writes editor-only JSON files to `META-INF/` alongside the standard EPUB structure:

| Path | Purpose |
|---|---|
| `com.humanist.pagemap.json` | Per-page anchor → chapter file map. Drives PDF/source/preview alignment commands. |
| `com.humanist.correction-trail.json` | Per-region Haiku post-OCR decisions (accepted + guardrail-rejected). Feeds the correction-trail review sheet. |
| `com.humanist.parsed-toc.json` | Haiku-parsed printed TOC + inferred page offset. Used for nav.xhtml chapter hrefs. |
| `com.humanist.chat.json` | Chat-with-book transcript. Persists across editor sessions; cleared via the trash button in the chat pane header. |

Standard EPUB readers ignore unknown `META-INF` files, so these round-trip through other tools cleanly.

## Plans

[PLANS.md](PLANS.md) tracks remaining work. The core conversion pipeline, editor, library, and the full Tier 9 conversion-quality push are all shipped. Active items are mostly distribution prep:

- **Code-signing + notarization** — see [RELEASES.md](RELEASES.md) for the full DMG / Developer ID / `notarytool` workflow.
- **Phase 10 distribution** — DMG hosting, optional Sparkle auto-updates. Deferred until there's a reason to ship beyond the current setup.
- **P-Greek-Quality** — measure Tesseract polytonic-Greek CER against hand-corrected ground truth.
- **Stretch (Tier 8)** — Apple Foundation Models on macOS 26+ for chapter classification, custom footnote styles, EPUB 3 audio overlays.

Phase 9 (RTL / Hebrew / Syriac / Coptic) is deferred indefinitely.
