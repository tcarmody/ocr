# Humanist

Native macOS app (macOS 26+) for turning PDFs and other documents into well-formatted EPUBs you can read, edit, search, and ask questions about. Built for academic content — polytonic Greek, Latin, mixed-script footnotes, printed tables of contents, figures with captions — but works just as well on contemporary trade books.

## What it does

- **Converts almost anything into clean EPUB 3.** Drop PDFs, Word documents, RTF, HTML, ODT, plain text, or Markdown onto the launcher and you get a properly-structured EPUB out the other end — real chapter navigation, table of contents, EPUB 3 popup footnotes, figures with captions, italic / bold preservation, semantic `epub:type` labels for front-matter and back-matter sections.

- **Reads scanned books faithfully.** The OCR pipeline cascades through Apple Vision → Surya layout analysis → Tesseract for classical scripts → optional Claude Sonnet for the hardest regions. Polytonic Greek, classical Latin, and mixed-script academic prose all survive. Two-up scans get auto-split. Scanner artifacts (long-s, ligatures, missing diacritics) get normalized through the typography pass and an optional Cloud cleanup step.

- **Gives you a real editor for the result.** Five-pane editor (original PDF, XHTML source, live preview, WYSIWYG, chat) with cross-pane synchronization at page and paragraph granularity. Find / replace across all chapters, formatting toolbar, spell check, footnote manager, chapter split / merge / move / rename with automatic internal-link rewriting, customizable per-book styling, EPUB validation via epubcheck.

- **Chats with one book or your whole library.** Hybrid retrieval (BM25 keyword + vector embedding + structural-hierarchy + named-entity) finds the right passages; the configured backend composes an answer with clickable citations that scroll directly to the cited paragraph. Markdown formatting in replies, model-suggested follow-up questions you can click to send, long-form synthesis toggle, retrieval-debug surface for diagnosing misfires.

- **Library-scope chat with first-class navigation.** The library window has its own chat pane that pulls across every indexed book. Cite a passage and one click opens that book in a new editor. Scope to a selection ("compare these five books on X"), save recurring scopes as named **collections** ("Foucault corpus"), exclude a book that keeps misfiring, or chat against your whole catalog. Bulk-index command pre-builds embeddings for every book in one go.

- **Organizes a personal library.** Every conversion is catalogued. Cover thumbnails, language filter, sortable columns, durable named **collections** as a sidebar, cross-book bulk find / replace, multi-selection that drives both bulk editing and chat scoping. **Import existing EPUBs** (`⇧⌘I`, drag-drop, or a whole folder full of subfolders) that didn't come from a PDF conversion — anchors get injected, on-device AFM extracts title + author from the front matter when Apple Intelligence is available, the book lands in the Books folder, and it joins the federated chat right away.

- **Runs entirely offline if you want.** Private mode is the default — Vision, Surya, Tesseract handle everything on the device. On macOS 26+ with Apple Intelligence enabled, Private mode *also* gets free on-device chapter classification, front-matter metadata extraction, and a coherence pass for recurring OCR errors via Apple's Foundation Models framework. Local chat backend (Ollama + Gemma 4 26B MoE) keeps the chat pane on-device too.

- **Optional Cloud features for pro-level quality.** Each Cloud feature toggles independently — Claude OCR for the cascade, table extraction, post-OCR cleanup (text-only or multimodal vision mode), printed-TOC parsing, semantic classification, coherence pass, metadata extraction, and full-page Sonnet OCR with adaptive routing + Batches API + parallelism for cost-efficient bulk runs. Per-book cost cap bounds the worst case. Pre-flight cost estimate appears before you click Convert.

- **Four embedding backends for chat retrieval.** Apple's on-device `NLEmbedding` (default; free; offline), Ollama (local; better quality on technical text), Voyage AI (cloud; best on academic English), and Google's `gemini-embedding-2` (cloud; best on multilingual / classical-script content). Each backend's API key has its own Test Connection button.

- **Produces a stack of output formats from one conversion.** EPUB, plain text, Markdown, self-contained HTML, DOCX, and a searchable PDF (your original with an invisible OCR text overlay — Cmd+F searchable, no visual change). All siblings stay in sync when you save edits.

- **Scriptable from the shell.** `humanist-cli convert / compare / validate` — same engines as the app, no GUI surface required. Useful for CI checks, batch jobs, or "run this on every PDF in the folder while I'm at lunch." On macOS 26+ in `--private` mode, the CLI inherits the same on-device chapter classification + metadata + coherence features as the app.

- **Embeds the file-system tools you'd need anyway.** PDF Join / Split, EPUB Join / Split, side-by-side EPUB diff, epubcheck wrapper. All under File Tools without needing to open an editor window.

## Inputs

| Format | Path |
|---|---|
| `.pdf` | Full OCR pipeline — scan detection, layout analysis, cascade OCR, EPUB build |
| `.txt` `.md` `.rtf` | Text ingest — paragraph detection, heading + emphasis preservation, direct EPUB build |
| `.docx` `.doc` `.odt` `.html` | Attributed-text ingest — heading styles, bold/italic from font traits, direct EPUB build |
| `.epub` | Library import — paragraph-anchor injection + cataloging + embedding sidecar (no re-OCR) |
| Folder | Queues every supported file inside |

## What the PDF pipeline does

Each PDF job runs through:

- **Two-up scan detection** — facing-page scans get auto-split with a confirmation prompt.
- **Language auto-detect** — `NLLanguageRecognizer` samples body pages and overrides the picker when confident.
- **Pre-flight cost estimate** — Cloud-mode jobs show projected Claude calls + dollar cost before you click Convert.
- **Embedded-text trust scoring** — clean text layers pass through untouched; broken `ToUnicode`, mojibake, or language-mismatched layers trigger full re-OCR.
- **Per-region OCR cascade** — Vision → Surya → Tesseract → optional Claude Sonnet for hard regions, gated on a per-region quality scorer.
- **Whole-page Claude OCR** (optional, ~$0.04/page) — one Sonnet call per page returns structured XHTML directly; bypasses the per-region cascade. Adaptive routing skips Sonnet on pages that score as trusted embedded text. Optional Batches API path (50% discount, async). Optional bounded parallelism.
- **Post-OCR Haiku cleanup** (optional) — fixes character-level errors (ligatures, missing diacritics, long-s) on low-quality regions. Text-only or multimodal (sends the region image alongside the OCR text).
- **Layout-aware reflow** — Surya classifies regions as text / heading / footnote / figure / table / caption; reflow respects the classification, repairs cross-page hyphenation, and normalizes typography (ligatures, dashes, smart quotes).
- **Figure extraction** — `.picture` and `.formula` regions raster-cropped into `OEBPS/images/`; cover-image detection for page-0 dominant figures.
- **Table extraction** — Surya `TableRecPredictor` (or Claude Sonnet under Cloud mode) with an X/Y heuristic fallback; emits proper `<table>` with `<thead>`/`<tbody>`/merged cells.
- **Footnote linking** — EPUB 3 popup notes: `<aside epub:type="footnote">` + `<a epub:type="noteref">`, so e-readers pop them up in place.
- **Printed-TOC parsing** (optional, one Haiku call) — extracts the printed table of contents into authoritative chapter titles and nav.xhtml entries.
- **Semantic chapter classification** — Cloud (Haiku, one call per chapter) or on-device (Apple Foundation Models, free on macOS 26+) labels each section with `epub:type` for semantic navigation.
- **Document coherence pass** — Cloud (Haiku, one call) or on-device identifies recurring OCR errors across all chapters and applies guarded global replacements.
- **Metadata extraction** — Cloud (Haiku, one call) or on-device pulls title, author, year, publisher, and ISBN from the front matter; writes them to OPF `<dc:*>` fields.
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

The launcher splits sibling outputs into two toggles: **`.txt + .md`** (cheap, on by default) and **`.html + .docx`** (heavier, off by default). All siblings are regenerated whenever you save the EPUB in the editor. An optional **configurable output folder** (Settings → Conversion) routes each format into its own subfolder (`Books/`, `Searchable PDFs/`, `Text Files/`, `Markdown/`, `HTML/`, `Word Documents/`). Settings → Conversion also holds **Conversion defaults** — toggles that seed the launcher's per-conversion switches (Surya OCR, Claude OCR, Force OCR, Private mode, Save log, sibling formats) each session; per-session changes in the launcher don't persist back. The same folder also gets an `Input/` subfolder used by the optional **auto-scan** feature: enable *Automatically scan Input folder for new PDFs* in Settings → Conversion and any PDF you drop into `Input/` while the launcher is running is enqueued with those defaults — same code path as a drag-drop conversion. PDFs whose output EPUB already exists are skipped. `Scripts/auto-scan-input.sh` is the headless companion for cron / launchd setups; it walks the same folder via `humanist-cli` and reads the same defaults from `defaults read com.humanist.macos humanist.conversion.default*`.

## Editor

Every produced EPUB opens in a five-pane editor:

| Pane | Key | Description |
|---|---|---|
| Original | ⌘1 | PDF source, synced to the source cursor via page anchors |
| Source | ⌘2 | XHTML markup in CodeMirror — formatting toolbar, find/replace, spell check |
| Preview | ⌘3 | Live rendered EPUB preview, auto-updates on save |
| WYSIWYG | ⌘4 | Contenteditable WebView rendered with the book's own CSS — formatting toolbar, syncs with Source on save |
| Chat | ⌘5 | Per-book chat with hybrid retrieval — see [Chat-with-book](#chat-with-book) below |

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

## Chat-with-book

Each editor's chat pane and the dedicated library chat window share one engine. Hybrid retrieval combines four signals via reciprocal rank fusion:

- **BM25** — keyword precision over chapters
- **Vector embeddings** — semantic recall across paragraphs (four backend choices: Apple `NLEmbedding`, Ollama, Voyage AI, Gemini)
- **Hierarchical structure** — when the query mentions a chapter or section title, paragraphs in that scope get boosted
- **Named entities** — Apple `NLTagger` over every paragraph; querying a person / place / org boosts paragraphs that mention it. User-editable alias dictionary covers terms NER misses (medieval scribal abbreviations, classical names, etc.)

**Chat surfaces:**

- **Per-book chat** (`⌘5` in the editor) — scoped to the open EPUB. A scope picker flips between "Current book" and "Whole library" without leaving the editor.
- **Library chat** (`⌘2` to show the Library, `⌘/` to reveal its chat pane) — first-class corpus chat. Citations carry the book + chapter, and one click opens the cited book in a new editor window. Multi-selection in the library table feeds a "Chat with Selected (n)" action that scopes the next session to those rows.

**Per-conversation features:**

- **Markdown formatting** in replies (bold, italic, headings, lists, code, blockquotes, fenced code blocks)
- **Suggested follow-ups** — model emits 2-3 next questions; one click sends as the next user turn
- **Long-form synthesis toggle** — switches the system prompt + lifts maxTokens for a few-paragraph essay-shaped reply when the question warrants it
- **Per-book exclusion** — right-click any citation chip to remove that book from the rest of the conversation
- **Retrieval debug surface** — toggle to show why each paragraph was picked (BM25 rank, embedding rank, hierarchy / entity matches)
- **Tunable knobs** in Settings → AI → Advanced retrieval — RRF k, top-K, max paragraph chars
- **Persistent transcripts** — per-book and library transcripts persist independently across sessions

**Answering backends** — pick one in Settings → AI → Book Chat:

- **Cloud (Haiku 4.5)** — fast, cheap (~$0.06/query at typical scope)
- **Cloud (Sonnet 4.6)** — better synthesis on comparative questions (~$0.19/query)
- **Local (Ollama)** — fully on-device (default Gemma 4 26B MoE; user can pick any local model)

## Library

The library window is a primary surface, not a sidebar. Every conversion lands here automatically. Cover thumbnails per row, sortable by title / language / added / last-opened, language filter, multi-selection.

- **Collections sidebar** — durable named groupings ("Foucault corpus", "for the chapter on biopolitics"). Right-click any row → *Add to Collection ▸* to drop it into an existing group or create a new one from the current selection. Click a collection in the sidebar to filter the table to its members; the filter bar swaps "Chat with Selected" for "Chat with {Collection}" so the whole group seeds the next chat in one click.
- **Import EPUB into Library…** (`⇧⌘I`) — multi-select picker brings existing `.epub` files into the catalog; folders work too (walked recursively for `.epub` descendants), and drag-drop on the Library window accepts both files and folders. Each source is opened, `<p>` paragraph anchors are injected where missing, the on-device AFM metadata extractor populates `<dc:title>` / `<dc:creator>` from the front matter when Apple Intelligence is available + the toggle is on, the result is repacked into the configured Books folder (or `~/Documents/Humanist Library/Books/`), catalogued, and its embedding sidecar is built so library chat sees it immediately. Re-import is idempotent — already-anchored books pass through unchanged.
- **Bulk find / replace** across selected books — runs through `BulkEditor` over the EPUBs' XHTML resources.
- **Bulk index** for the chat embeddings — walks every catalog entry and builds (or refreshes) its sidecar against the user's chosen backend, with cancellable progress and per-book failure list.
- **Embedded chat pane** (`⌘/` to toggle) — see [Chat-with-book](#chat-with-book).
- **Window-switcher chords** — `⌘1` / `⌘2` / `⌘3` / `⌘4` reveal Converter / Library / most-recent Editor / Queue.

## File Tools

Four file-system utilities that work without opening any editor window:

- **PDF Join** — concatenate N PDFs into one
- **PDF Split** — extract page ranges into separate PDFs
- **EPUB Join** — merge N EPUBs, each source under its own subdirectory
- **EPUB Split** — split one EPUB into chapter-range parts

## Command-line interface

A second executable target — `humanist-cli` (currently 1.1.0) — exposes the same Pipeline and EPUB modules as a scriptable shell tool. Same engines, same conversion quality, no GUI surface.

```sh
swift build --product humanist-cli -c release
cp "$(swift build --show-bin-path -c release)/humanist-cli" ~/.local/bin/

humanist-cli convert paper.pdf                     # default → paper.epub
humanist-cli convert paper.pdf -f md               # markdown only
humanist-cli convert book.pdf -f epub,md,html,docx -o ./out
humanist-cli convert paper.docx -f md              # DOCX → MD, bypasses OCR
humanist-cli convert book.pdf --private            # offline; AFM features on macOS 26+
humanist-cli compare old.epub new.epub             # paragraph-level diff
humanist-cli validate book.epub                    # epubcheck wrapper
```

Per-feature Cloud toggles are individual (`--no-claude-tables`, `--no-coherence-pass`, etc.); `--private` forces all off. API key reads from `$ANTHROPIC_API_KEY`. JSON output mode (`--json`) for CI / scripts. Full reference at [Sources/HumanistCLI/README.md](Sources/HumanistCLI/README.md).

## Setup wizards

External dependencies are installed by the user on first launch via in-app wizards rather than bundled in the .app — keeps the bundle tiny (~16 MB), keeps notarization simple, and lets users opt out of any dependency they don't need:

- **Surya** (~1 GB) — layout analysis. Without it the cascade falls back to Vision-only OCR with no region classification. Banner appears on the launcher when not installed; wizard at *Welcome → Set up Surya…* uses `uv tool install surya-ocr`.
- **Tesseract** (~150 MB) — classical-script OCR (polytonic Greek, Latin, Hebrew). The "Tesseract not installed" badge is contextual — only shows when your language selection would benefit. Wizard installs via `brew install tesseract tesseract-lang`.
- **Ollama + Gemma 4 26B MoE** (~18 GB) — local chat backend. Optional; the chat pane defaults to Cloud (Haiku). Wizard at *Settings → AI → Set Up Local Chat…* walks through `ollama pull gemma4:26b`.

Each wizard mirrors the same three-step flow: install the package manager (Homebrew / uv / Ollama), install the dependency, verify. Live streamed install output, contextual error messages, and a "Skip" option that's always honored.

## Privacy posture

**Private mode is the default.** Everything runs locally — Vision, Surya, Tesseract — and no data leaves your machine. On macOS 26+ with Apple Intelligence enabled, Private mode *also* gets free on-device chapter classification, front-matter metadata extraction, and a coherence pass through Apple's Foundation Models framework — features that previously required Cloud-mode + an Anthropic key.

Cloud features only run when you flip Settings → AI → Processing Mode to Cloud and provide an Anthropic API key (stored in the macOS Keychain). Per-feature toggles let you opt in one at a time; a per-book call cap bounds the worst-case cost. Voyage and Gemini API keys (used for chat embeddings only) are similarly opt-in and per-keychain.

## Build and run

```sh
Scripts/run-app.sh          # release build + assemble .app + sign + open
swift test                  # 881 unit tests across 89 test files
```

`Scripts/run-app.sh` is the only supported launch path. `swift run` / `swift build` produce a bare binary without the bundled `Resources/` directory — the editor's CodeMirror source pane and the Surya layout sidecar won't load.

### Cloud-mode setup (optional)

1. Get an Anthropic API key from <https://console.anthropic.com>.
2. Open Settings (⌘,) → **AI → Anthropic API Key** and paste the key. Stored in the macOS Keychain.
3. Switch **Processing Mode** to Cloud and enable the features you want (hard-region OCR, table extraction, post-OCR cleanup, coherence pass, metadata extraction, TOC parsing, semantic classification).
4. Drop a PDF. The queue row shows a pre-flight cost estimate before the conversion starts.

Typical cost is pennies to a few dollars per book depending on which features are on and whether you use the whole-page Sonnet path.

### Chat embedding setup (optional)

The default embedding backend is Apple's on-device `NLEmbedding` — free, offline, no setup. To upgrade:

- **Voyage AI** (best on academic English) — get a key at <https://voyageai.com>; paste under Settings → AI → Chat Retrieval → Voyage. Test Connection button runs a one-token probe.
- **Gemini Embedding 2** (best on multilingual / classical-script content) — get a key at <https://aistudio.google.com>; same pattern. Matryoshka output (truncate to 768 / 1536 / full ~3072 dim) for storage / quality tradeoffs.
- **Ollama embeddings** — pull `nomic-embed-text` or similar; paste the model tag under Settings → AI → Chat Retrieval.

## Source layout

```
ocr/
├── Package.swift
├── Sources/
│   ├── Humanist/                    SwiftUI app — launcher, editor, library, settings, file tools, setup wizards
│   │   ├── Editor/Chat/             22 files: per-book + library chat, BM25 + embedding + hierarchy + entity indexes,
│   │   │                             alias dictionary, follow-up parser, Markdown rendering, retrieval debug
│   │   └── Library/                 Library window (browser + bulk index + chat pane)
│   ├── HumanistCLI/                 `humanist-cli` executable — convert/compare/validate from the shell
│   ├── Document/                    Canonical IR — Book / Chapter / Block / InlineRun / Footnote
│   ├── PDFIngest/                   PDFKit rendering, embedded-text scoring, two-up detection, language profiler
│   ├── OCR/                         OCREngine protocol — Vision, Tesseract, embedded-text gap-filler
│   ├── Layout/                      Surya sidecar bridge + region classification
│   ├── Pipeline/                    Orchestration: source → cascade → reflow → chapters → EPUB + siblings + DOCX
│   │                                Includes shared protocol-conforming engines (Cloud + on-device)
│   ├── EPUB/                        Book IR → EPUB 3 zipfile; XHTML / nav / OPF writers; in-memory editor model;
│   │                                differ + validator
│   └── AI/                          22 files: Anthropic + Ollama + Voyage + Gemini + Apple Foundation Models clients,
│                                    embedding backends, settings, key stores
├── Tests/                           881 unit tests across 89 test files
├── Resources/
│   └── codemirror/                  Vendored CodeMirror 5 for the editor's source pane
├── Sidecars/
│   └── layout/sidecar.py            Surya layout + table model, Python via uv
├── BundleAssets/
│   ├── Info.plist
│   └── Humanist.entitlements
└── Scripts/
    ├── build-app.sh                 swift build + assemble .app + sign
    ├── run-app.sh                   build + open
    └── build-icon.sh
```

### Per-EPUB sidecars

Humanist writes editor-only JSON files inside `META-INF/` alongside the standard EPUB structure:

| Path | Purpose |
|---|---|
| `com.humanist.pagemap.json` | Per-page anchor → chapter file map. Drives PDF/source/preview alignment commands. |
| `com.humanist.paragraph-map.json` | Per-paragraph anchor → PDF page + bbox. Drives paragraph-level Re-OCR + finer source/preview sync. |
| `com.humanist.correction-trail.json` | Per-region Haiku post-OCR decisions (accepted + guardrail-rejected). Feeds the correction-trail review sheet. |
| `com.humanist.parsed-toc.json` | Haiku-parsed printed TOC + inferred page offset. Used for nav.xhtml chapter hrefs. |

Standard EPUB readers ignore unknown `META-INF` files, so these round-trip through other tools cleanly.

### Application Support sidecars

Editor / chat state that's user-scoped rather than book-scoped lives outside the EPUB at `~/Library/Application Support/Humanist/`:

| Path | Purpose |
|---|---|
| `Chats/<sha256>.json` | Per-book chat transcript, keyed by canonical EPUB path. |
| `Chats/library.json` | Library chat transcript (one per user). |
| `Embeddings/<sha256>.json` | Per-book embedding sidecar — paragraph vectors + hierarchy index + entity index, keyed by canonical EPUB path. |
| `Aliases/aliases.json` | Per-library alias dictionary for entity retrieval. |
| `library.json` | Library catalog. |
| `queue.json` | Conversion queue snapshot. |

Storing chat / embedding state outside the EPUB keeps the file portable (a copy you give to someone else doesn't carry your chat history) and avoids re-zipping the EPUB on every save.

## Plans

[PLANS.md](PLANS.md) tracks remaining work in detail. The core conversion pipeline, editor, library, multi-book chat, on-device classification (Apple Foundation Models Phases 1+2), R-Library-Chat-Plus Tier 1 (Chat with Selected, Collections, Suggested follow-ups, Long-form synthesis, Per-book exclusion), and R-EPUB-Import v1 are all shipped. Active items:

- **R-Library-Chat-Plus Tier 2** — citation export, conversation export, pinned passages, ask-each-book mode.
- **E-Vision-Modes** — Manuscript mode (Claude Opus 4.7, diplomatic transcription) and Early Print mode (Gemini 3 Pro, fluent normalization). Validation spike planned.
- **L-Foundation-Models Phase 2.5 + 3** — on-device post-OCR cleanup + TOC parsing.
- **R-EPUB-Import chapter classification / coherence on import** — title + author already lift out of front matter via AFM; the remaining engines need an XHTML → Chapter IR parser the import path doesn't have today.
- **Distribution polish** — Developer ID cert, notarization, DMG, GitHub Releases. See [RELEASES.md](RELEASES.md).
- **P-Greek-Quality** — measure Tesseract polytonic-Greek CER against hand-corrected ground truth.

Phase 9 (RTL / Hebrew / Syriac / Coptic) is deferred indefinitely — corpus doesn't justify the bidi-rendering and per-script accuracy lifts.
