# Humanist

Native macOS app (macOS 26+) for turning PDFs and other documents into well-formatted EPUBs you can read, edit, search, and ask questions about. Built for academic content — mathematical formulas, polytonic Greek, mixed-script footnotes, printed tables of contents, figures with captions — but works just as well on contemporary trade books or technical articles.

## What it does

- **Converts almost anything into clean EPUB 3.** Drop PDFs, Word documents, RTF, HTML, ODT, plain text, or Markdown onto the launcher and you get a properly-structured EPUB out the other end — real chapter navigation, table of contents, EPUB 3 popup footnotes, figures with captions, italic / bold preservation, semantic `epub:type` labels for front-matter and back-matter sections.

- **Reads scanned books faithfully.** The OCR pipeline cascades through Apple Vision → Surya layout analysis → Tesseract for classical scripts → optional **Google Document OCR** ($1.50/1000 calls; absorbs the hard-region tail at classical-OCR pricing) → optional Claude Sonnet for the residual that everything else couldn't read. An alternative **whole-page OCR mode** sends each rendered page directly to a multimodal model that returns structured XHTML in one call; pick the provider in Settings → AI: **Claude Sonnet 4.6** (highest quality on dense academic layouts, ~$0.04/page), **Gemini 2.5 Flash** (GA; ~7–10× cheaper than Sonnet at comparable quality on typeset prose, ~$0.005/page), **Gemini 3 Flash preview** (newer reasoning model; ~$0.006/page with `thinking_level: minimal` pinned), or **Gemini 3.5 Flash** (experimental; stable model from Google I/O 2026, ~$0.02/page — half Sonnet's cost, no published document-OCR benchmarks so worth A/B-ing against your own corpus). Polytonic Greek, classical Latin, and mixed-script academic prose all survive. Two-up scans get auto-split. Scanner artifacts (long-s, ligatures, missing diacritics) get normalized through the typography pass and an optional Cloud cleanup step. **Early Print mode** (Sonnet 4.6 or Gemini Flash with a normalizing-posture prompt) handles 15th–18th c. printed books — silently modernizes long-s, u/v, i/j, and standard ligatures; preserves period spelling; covers Roman / Blackletter (Fraktur) / Italic typefaces. **Manuscript mode** (Claude Opus 4.7; provider-pinned because handwriting needs Opus's visual reasoning) handles handwritten material with hand-family-specific prompts: 16th–17th c. secretary hand (diplomatic transcription, abbreviation expansion in italics), 18th c. round hand (copperplate; period spelling preserved), 19th–early 20th c. cursive, and modern handwriting.

- **Gives you a real editor for the result.** Five-pane editor (original PDF, XHTML source, live preview, WYSIWYG, chat) with cross-pane synchronization at page and paragraph granularity. Find / replace across all chapters, formatting toolbar, spell check, footnote manager, chapter split / merge / move / rename with automatic internal-link rewriting, customizable per-book styling, EPUB validation via epubcheck.

- **And a real reader, too.** Opening an `.epub` defaults to a distraction-free reader window — three-column layout (TOC sidebar | reading pane | chat sidebar), scroll *or* paginated layout (CSS-columns; ←/→/space page navigation, "page N / M" indicator), and reading preferences (font face, line spacing, margins, System / Sepia / Dark themes) that live-update without a chapter reload. Position is persisted per-book (resumes at the exact sub-chapter offset you left at; survives reopen and crashes), and the Library window shows a *Reading* column with "Ch. N · 2 d ago"-style status per row. Bookmarks (⌘D), highlights (⌃⌘H), and passages-with-notes are unified in an annotations sidebar with copy-with-citation (⇧⌘C); right-click selected text for the same actions. Find-in-chapter (⌘F). The chat sidebar is the same engine as Library chat, locked to the current book — citations snap the reading pane to the cited paragraph. The Editor is one click away via *Edit Source…* (⌥⌘O); if you save in the Editor while the Reader is open, the Reader shows a "Book changed on disk — Reload" banner instead of silently going stale.

- **Chats with one book or your whole library.** Hybrid retrieval (BM25 keyword + vector embedding + structural-hierarchy + named-entity) finds the right passages; the configured backend composes an answer with clickable citations that **always open the cited book in the reader and snap to the paragraph cited** (regardless of which default surface you've chosen — citations are anchored navigation, not a chrome preference). Markdown formatting in replies, model-suggested follow-up questions you can click to send, long-form synthesis toggle, retrieval-debug surface for diagnosing misfires. Per-book chat also exposes a **pre-reading briefing** (closed-book toolbar glyph): one-shot streamed overview of *what the book is doing*, *the tradition it sits in*, *cross-references you already own*, and *what to watch for* — cross-references are embedding-retrieved from your federated library index (top-40 nearest neighbors, not the full catalog) so the briefing names books actually adjacent to the read. Briefings persist to `~/Library/Application Support/Humanist/Briefings/` so reopening is instant; a Retry button forces a regenerate when the cache should bust.

- **Customizable chat appearance.** Settings → Chat → Appearance has three knobs that apply across all three chat surfaces (editor, library, reader): **font family** (System / Serif — New York on macOS 26), **font size** (Small / Medium / Large / Extra Large), and **color scheme** (Match System / Light / Dark — forces the chat panes regardless of the surrounding window). Changes propagate without a window relaunch.

- **Library-scope chat with first-class navigation.** The library window has its own chat pane that pulls across every indexed book. Cite a passage and one click opens that book in the reader at the cited paragraph. Scope to a selection ("compare these five books on X"), save recurring scopes as named **collections** ("Foucault corpus"), exclude a book that keeps misfiring, or chat against your whole catalog. Bulk-index command pre-builds embeddings for every book in one go. **Tool-use chat** (agentic loop) is wired into both library scope and per-book scope: the model can call `search_library` / `search_topic` (library) or `search_book` / `expand_chapter` / `list_chapter_titles` (per-book) mid-conversation to fetch passages it didn't see in the first retrieval pass — same path on Cloud (Sonnet / Haiku) and on Ollama (qwen3.5:9b is the new default; gemma4:26b can't do tool calls).

- **Topics index.** A library-wide concept rollup ("Topics") lives behind the toolbar tag button (sparkles-style sheet popup) — entity-map inversion across every indexed book surfaces the people / places / works that recur, with per-topic book counts and a one-click jump to the passages where each topic appears. Same data feeds the `search_topic` tool the library chat agentic loop can call.

- **Organizes a personal library.** Every conversion is catalogued. Cover thumbnails, language filter, sortable columns, durable named **collections** as a sidebar, cross-book bulk find / replace, multi-selection that drives both bulk editing and chat scoping. **Auto-generated collections** — Print / Manuscript / Early Print / Digital buckets by conversion type; one per author with 3+ books in your library (threshold configurable); per-genre via an on-device closed-taxonomy AFM classifier covering humanities (Poetry, Drama, Fiction sub-genres, Philosophy, History, Religion, Linguistics, Arts) and technical material (Mathematics, Science sub-genres, Technology sub-genres including Computing, Social Science sub-genres). One click in the sidebar header to refresh from existing metadata; a separate Classify button (`wand.and.stars`) runs the genre classifier on books without a genre stamp. **Import existing EPUBs** (`⇧⌘I`, drag-drop, or a whole folder full of subfolders) that didn't come from a PDF conversion — anchors get injected, on-device AFM extracts title + author from the front matter when Apple Intelligence is available, the book lands in the Books folder, and it joins the federated chat right away. The catalog can also **sync across Macs** via a cloud folder: enable *Share library across machines* in Settings → Conversion and `library.json` + the alias dictionary move into `<output folder>/.humanist/`. Both Macs see the same books, same custom vocabulary, same per-book metadata + collection memberships. Embedding sidecars stay machine-local — each Mac builds its own — but a per-source-hash claim list on the shared catalog stops two Macs from converting the same Input/ PDF simultaneously. Auto-catalog on editor-open means every EPUB you open joins the library automatically.

- **Runs entirely offline if you want.** Private mode is the default — Vision, Surya, Tesseract handle everything on the device. On macOS 26+ with Apple Intelligence enabled, Private mode *also* gets free on-device chapter classification, front-matter metadata extraction, and a coherence pass for recurring OCR errors via Apple's Foundation Models framework. Local chat backend (Ollama + Gemma 4 26B MoE) keeps the chat pane on-device too.

- **Optional Cloud features for pro-level quality.** Each Cloud feature toggles independently — Claude OCR for the cascade, Google Document OCR as a cascade Stage 2.5 ($1.50/1000 calls), table extraction, post-OCR cleanup (text-only or multimodal vision mode), printed-TOC parsing, semantic classification, coherence pass, metadata extraction, and full-page OCR with adaptive routing + Batches API + parallelism for cost-efficient bulk runs. **Page-OCR provider is selectable**: Claude Sonnet 4.6 (the original; best on dense academic layouts), Gemini 2.5 Flash (~7–10× cheaper per page with comparable quality on typeset prose), Gemini 3 Flash preview (newer reasoning model; preview status), or Gemini 3.5 Flash (Google I/O 2026; stable; sits between 3 Flash Preview and Sonnet on cost — experimental for our workload). Per-book cost cap bounds the worst case. Pre-flight cost estimate appears before you click Convert. Post-conversion stats surface a **per-page refusal rate** so policy refusals don't silently degrade quality.

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
- **Per-region OCR cascade** — Vision → Surya → Tesseract → optional Google Document OCR (Cloud Vision `DOCUMENT_TEXT_DETECTION`, ~$0.0015/call) → optional Claude Sonnet for the residual, each tier gated on a per-region quality scorer.
- **Whole-page page-OCR** (optional) — one provider call per page returns structured XHTML directly; bypasses the per-region cascade. Provider selectable in Settings → AI: Claude Sonnet 4.6 (~$0.04/page; baseline), Gemini 2.5 Flash (~$0.005/page; GA), Gemini 3 Flash preview (~$0.006/page; preview, `thinking_level: minimal` pinned), or Gemini 3.5 Flash (~$0.02/page; experimental, May 2026 release). Adaptive routing skips the call on pages that score as trusted embedded text. Optional Batches API path (Claude only, 50% discount, async). Optional bounded parallelism. Per-page refusal rate is tracked and surfaced in the post-conversion stats panel.
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
- **Facing-page bilingual detection** — Loeb Classical Library style editions (verso = classical original, recto = English translation) are auto-detected post-OCR via Unicode-script ratios for Greek / Hebrew, a Latin function-word fingerprint, and `NLLanguageRecognizer` for everything else. Each page anchor gets a `data-facing-page` attribute pointing to its partner so spreads stay linked in the EPUB. Conservative thresholds (≥80% alternation, classical L1 only) — auto-detect doesn't fabricate bilinguals. The launcher's *Per-job overrides* has a **Facing-page bilingual** toggle that relaxes the gates for edge cases (modern-language bilinguals, alternation broken by footnotes); CLI parity via `--force-bilingual-facing-page`.

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

The launcher splits sibling outputs into two toggles: **`.txt + .md`** (cheap, on by default) and **`.html + .docx`** (heavier, off by default). All siblings are regenerated whenever you save the EPUB in the editor. An optional **configurable output folder** (Settings → Conversion) routes each format into its own subfolder (`Books/`, `Searchable PDFs/`, `Text Files/`, `Markdown/`, `HTML/`, `Word Documents/`). Settings → Conversion also holds **Conversion defaults** — toggles that seed the launcher's per-conversion switches (Surya OCR, Claude OCR, Force OCR, Private mode, Save log, sibling formats) each session; per-session changes in the launcher don't persist back. The same folder also gets an `Input/` subfolder used by the optional **auto-scan** feature: enable *Automatically scan Input folder for new PDFs* in Settings → Conversion and any PDF you drop into `Input/` while the launcher is running is enqueued with those defaults — same code path as a drag-drop conversion. The scanner skips PDFs that match an existing catalog entry's source-hash, PDFs the user has explicitly tombstoned via the remove dialog's *Trash & Don't Re-scan Source* button, and PDFs another Mac is currently converting (via the in-flight claim list on the shared catalog). The conversion queue can be paused / resumed any time from the launcher toolbar; a *Start paused on launch* preference in Settings → Conversion → Queue lets you keep the queue quiescent until you explicitly resume each session. `Scripts/auto-scan-input.sh` is the headless companion for cron / launchd setups; it walks the same folder via `humanist-cli` and reads the same defaults from `defaults read com.humanist.macos humanist.conversion.default*`.

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

## Reader

Opening an `.epub` (Library double-click, File → Open, drag-drop, Recents) routes to the reader scene by default; the editor is reachable via the reader's *Edit Source…* (⌥⌘O) action or the Window menu's *Show Editor* (⌘3). Settings → **Reader** has a *Double-click opens books in* picker to flip the default to **Source Editor** instead — applies to every open path that goes through `OpenRouter.open` (so library double-click and File → Open stay consistent). The reader is its own window class (*Show Reader* — ⌘5) with sibling per-URL window-reuse semantics, so opening the same book twice reveals the existing window.

**Layout:**

- Three-column `NavigationSplitView` — **TOC sidebar** (parsed `nav.xhtml`, clickable; sub-chapter scroll inside a chapter as well) | **reading pane** (WKWebView with the book's own CSS) | **chat sidebar** (collapsible, on by default; toggle with ⌥⌘C).
- **Scroll layout** (default) or **paginated layout** (⌥⌘P toggles) — paginated uses CSS multi-column to lay out one viewport-sized page at a time; ←/→/space page nav, "page N / M" indicator.
- **Sidebar tabs** — *Contents* (TOC) and *Marks* (annotations list, grouped + counted). Tab choice and collapse state persisted per `@AppStorage` so a user who lives in the annotations list stays there on reopen.

**Reading preferences** (toolbar popover, ⌃⌘A; live-updates without chapter reload):

- Font face — Serif (Iowan Old Style → Hoefler → Georgia), New York, Sans-serif (San Francisco / Helvetica Neue), Monospace (SF Mono / Menlo)
- Font size, line spacing (1.2×–2.2×), margin width (0–8em)
- Theme — System / Sepia / Dark

**Position persistence:**

- Reading position is keyed by EPUB content-hash, stored at `Application Support/Humanist/ReadingPositions/<sha256>.json`. Survives Library purges; non-library opens resume too.
- Records chapter + sub-chapter scroll fraction (and page index in paginated mode), debounced ~500 ms.
- The Library window's **Reading** column reads the same store and shows three states per row: *Not started*, *Started*, or *Ch. N · 2 d ago*-style status with chapter + abbreviated relative time.

**Annotations** (all keyed by content hash; sidecar at `Application Support/Humanist/Annotations/<sha256>.json`):

- **Bookmarks** (⌘D) — chapter + nearest paragraph anchor, no selection required.
- **Highlights** (⌃⌘H) — yellow span wrapped around the selection; restored on chapter reload via the persisted text + char-offsets (text match first, offsets second so minor edits don't strand the highlight).
- **Passages** — a highlight with a note attached; gets an additional underline accent and persists the note alongside.
- **Annotations sidebar** — per-chapter rows with kind icon, preview text, jump-to action; right-click *Add Note…* / *Edit Note…* / *Delete* on any row.
- **Right-click in the reading pane** — when text is selected, the WKWebView's context menu adds *Highlight* / *Add Note…* / *Copy with Citation* above the system items. *Add Note…* creates the highlight and opens the note editor immediately, so selection → passage with note is one gesture.

**Find:**

- ⌘F opens a find bar against the current chapter; uses `WKWebView.find` (native search highlighting + scroll into view). Esc dismisses.

**Copy with Citation** (⇧⌘C):

- Captures the current selection plus the nearest paragraph anchor + chapter and writes the clipboard as quoted text with a citation suffix (`"…" — Chapter Title, ¶N` style). Paragraph-level granularity, not just chapter.

**Chat sidebar — current book only:**

- Same `BookChatViewModel` + retrieval pipeline as the editor's chat pane, locked to `.currentBook` scope (no scope picker, no exclusion row, no federated-index status — those stay in the Library window's chat). Citation chips snap the reading pane to the cited spine index + paragraph anchor.
- **Full chrome parity** with the editor and library chat surfaces: long-form synthesis toggle, pre-reading briefing, pop-out to dedicated `book-chat` window (read and chat side-by-side), retrieval-debug toggle, export, clear. Chat appearance (font / size / theme) follows the same `@AppStorage` keys as the other surfaces — change in Settings and all three update without relaunching.

## Chat-with-book

Each editor's chat pane and the dedicated library chat window share one engine. Hybrid retrieval combines four signals via reciprocal rank fusion:

- **BM25** — keyword precision over chapters
- **Vector embeddings** — semantic recall across paragraphs (four backend choices: Apple `NLEmbedding`, Ollama, Voyage AI, Gemini)
- **Hierarchical structure** — when the query mentions a chapter or section title, paragraphs in that scope get boosted
- **Named entities** — Apple `NLTagger` over every paragraph; querying a person / place / org boosts paragraphs that mention it. User-editable alias dictionary covers terms NER misses (medieval scribal abbreviations, classical names, etc.)

**Chat surfaces:**

- **Per-book chat** (`⌘5` in the editor) — scoped to the open EPUB. A scope picker flips between "Current book" and "Whole library" without leaving the editor.
- **Library chat** (`⌘2` to show the Library, `⌘/` to reveal its chat pane) — first-class corpus chat. Citations carry the book + chapter, and one click opens the cited book in a new editor window. Multi-selection in the library table feeds a "Chat with Selected (n)" action that scopes the next session to those rows.

**Per-conversation features (full chrome parity across editor / library / reader):**

- **Markdown formatting** in replies (bold, italic, headings, lists, code, blockquotes, fenced code blocks)
- **Suggested follow-ups** — model emits 2-3 next questions; one click sends as the next user turn
- **Long-form synthesis toggle** — switches the system prompt + lifts maxTokens for a few-paragraph essay-shaped reply when the question warrants it
- **Pre-reading briefing** (per-book surfaces only) — closed-book glyph streams a one-shot briefing; embedding-retrieved cross-references; persisted to disk so reopening is instant; Retry button regenerates
- **Pop out to window** — `macwindow.badge.plus` opens the chat in the dedicated `book-chat` / `library-chat` window scene (smoother on long transcripts; the embedded pane stays put)
- **Export transcript** — `square.and.arrow.up` writes the conversation as Markdown with resolved citations to the clipboard
- **Clear transcript** — trash icon wipes the persisted transcript for this surface
- **Per-book exclusion** — right-click any citation chip to remove that book from the rest of the conversation
- **Retrieval debug surface** — toggle to show why each paragraph was picked (BM25 rank, embedding rank, hierarchy / entity matches)
- **Tunable knobs** in Settings → AI → Advanced retrieval — RRF k, top-K, max paragraph chars
- **Persistent transcripts** — per-book and library transcripts persist independently across sessions

**Answering backends** — pick one in Settings → AI → Book Chat:

- **Cloud (Haiku 4.5)** — fast, cheap (~$0.06/query at typical scope)
- **Cloud (Sonnet 4.6)** — better synthesis on comparative questions (~$0.19/query)
- **Local (Ollama)** — fully on-device. Default is **qwen3.5:9b** (~5 GB), which supports tool calls so the agentic loop's `search_book` / `search_topic` / `search_library` tools fire on local too. Existing setups keep their previously-chosen model via `@AppStorage`; only fresh installs see the new default. Picking any model in Settings → AI → Local Chat is supported, but tool-capable models (qwen3.5:9b, llama3.1:8b, etc.) are the right choice if you want the agentic retrieval path.

## Library

The library window is a primary surface, not a sidebar. Every conversion lands here automatically. Cover thumbnails per row, sortable by title / language / added / last-opened, language filter, multi-selection.

- **Collections sidebar** — durable named groupings ("Foucault corpus", "for the chapter on biopolitics"). Right-click any row → *Add to Collection ▸* to drop it into an existing group or create a new one from the current selection. Click a collection in the sidebar to filter the table to its members; the filter bar swaps "Chat with Selected" for "Chat with {Collection}" so the whole group seeds the next chat in one click.
- **Import EPUB into Library…** (`⇧⌘I`) — multi-select picker brings existing `.epub` files into the catalog; folders work too (walked recursively for `.epub` descendants), and drag-drop on the Library window accepts both files and folders. Each source is opened, `<p>` paragraph anchors are injected where missing, the on-device AFM metadata extractor populates `<dc:title>` / `<dc:creator>` / `<dc:date>` / `<dc:publisher>` / ISBN from the front matter when Apple Intelligence is available + the toggle is on (ISBN goes in as a separate `<dc:identifier>urn:isbn:…</dc:identifier>` so the package's unique-identifier stays untouched), the on-device chapter classifier labels each `<body>` with the matching `epub:type` (preserving any publisher-set label), the result is repacked into the configured Books folder (or `~/Documents/Humanist Library/Books/`), catalogued, and its embedding sidecar is built so library chat sees it immediately. Re-runs short-circuit on already-imported books (file + catalog row + matching sidecar = skip the whole pipeline); mid-batch cancel responds in seconds. For really big batches (hundreds–thousands of books), Settings → Conversion → EPUB import has a *Skip embedding index build on import* toggle that defers the per-book embedding work to a separate overnight bulk-index run.
- **Bulk find / replace** across selected books — runs through `BulkEditor` over the EPUBs' XHTML resources.
- **Bulk index** for the chat embeddings — walks every catalog entry and builds (or refreshes) its sidecar against the user's chosen backend, with cancellable progress and per-book failure list.
- **Re-scan with current settings** — right-click any catalog row → *Re-scan with Current Settings…*. Probes for the original source PDF (sibling, configured output root, OPF `<dc:source>`, prior drop paths) and falls through to a file picker when nothing auto-resolves. Re-runs the OCR pipeline with the launcher's current toggles and overwrites the existing EPUB, preserving the catalog row + your metadata edits + collection memberships. The old EPUB is copied to `<basename>.bak.epub` first for one-click rollback.
- **Reading column** — alongside title / language / added / last-opened, every row carries a Reading-progress cell sourced from the reader's per-book `ReadingPositionStore`: *Not started* / *Started* / *Ch. N · 2 d ago*. Updates in real time as the reader scrolls.
- **Find Missing Files…** (File menu) — companion to the silent file-exists prune at launch: walks the catalog, runs `fileExists` and `EPUBPackage.open` against each entry, and opens a review sheet listing the broken ones (badge: *Missing* or *Won't open*, with the error message for unopenable files, last-opened date, full path). Default-checked checkbox per row so users on temporarily-offline volumes can uncheck and keep their entries. Apply removes via the standard `LibraryStore.remove(_:)` so collection memberships clean up alongside.
- **Embedded chat pane** (`⌘/` to toggle) — see [Chat-with-book](#chat-with-book).
- **Window-switcher chords** — `⌘1` / `⌘2` / `⌘3` / `⌘4` reveal Converter / Library / most-recent Editor / Queue.

## File Tools

Four file-system utilities that work without opening any editor window:

- **PDF Join** — concatenate N PDFs into one
- **PDF Split** — extract page ranges into separate PDFs
- **EPUB Join** — merge N EPUBs, each source under its own subdirectory
- **EPUB Split** — split one EPUB into chapter-range parts

## Command-line interface

A second executable target — `humanist-cli` (currently 1.2.0) — exposes the same Pipeline and EPUB modules as a scriptable shell tool. Same engines, same conversion quality, no GUI surface.

```sh
swift build --product humanist-cli -c release
cp "$(swift build --show-bin-path -c release)/humanist-cli" ~/.local/bin/

humanist-cli convert paper.pdf                                # default → paper.epub
humanist-cli convert paper.pdf -f md                          # markdown only
humanist-cli convert book.pdf -f epub,md,html,docx -o ./out
humanist-cli convert paper.docx -f md                         # DOCX → MD, bypasses OCR
humanist-cli convert book.pdf --private                       # offline; AFM features on macOS 26+
humanist-cli compare old.epub new.epub                        # paragraph-level diff
humanist-cli compare-corpus --dir <corpus> --limit 3          # quality-regression harness
humanist-cli validate book.epub                               # epubcheck wrapper
humanist-cli library-dedupe                                   # content-hash dedupe report
humanist-cli clear-outdated --backend gemini --apply          # delete sidecars off the current backend
humanist-cli reindex --backend gemini --limit 5               # headless rebuild via BookSidecarBuilder
```

Per-feature Cloud toggles are individual (`--no-claude-tables`, `--no-coherence-pass`, etc.); `--private` forces all off. API key reads from `$ANTHROPIC_API_KEY`. JSON output mode (`--json`) for CI / scripts. Long-running `reindex` / `clear-outdated` cycles are safe to wrap in `caffeinate -i` so the Mac doesn't idle-sleep mid-job. Full reference at [Sources/HumanistCLI/README.md](Sources/HumanistCLI/README.md).

## Setup wizards

Tesseract (libtesseract + libleptonica + transitive image-format dylibs + eng/grc/lat/heb traineddata) is **bundled inside the .app** as of 2026-05-15 — ~19 MB added to the bundle in exchange for "drag to /Applications, it works." The dylibs are weak-linked, so the app boots even if a bundle is shipped without them. No Homebrew required for the default OCR path.

External dependencies that *are* installed by the user on first launch via in-app wizards (kept out of the bundle for size or licensing reasons):

- **Surya** (~1 GB) — layout analysis. Strongly recommended for image, table, and layout detection on scanned books. Without it the pipeline still works: born-digital figures are extracted via a PDFKit content-stream walker (pixel-perfect bboxes from embedded image XObjects), and scanned-book figures fall through to an Apple Vision saliency detector (lower quality than Surya, but non-zero figure recall). Tables won't be extracted as structured `<table>` elements without Surya. Banner appears on the launcher when not installed; wizard at *Welcome → Set up Surya…* uses `uv tool install surya-ocr`.
- **Additional Tesseract languages** — eng/grc/lat/heb ship bundled; other languages (Arabic, Chinese, Japanese, Korean, Sanskrit, Coptic, Syriac, etc.) can be added via `brew install tesseract-lang` and the cascade picks them up automatically once the data is on disk.
- **Ollama + Gemma 4 26B MoE** (~18 GB) — local chat backend. Optional; the chat pane defaults to Cloud (Haiku). Wizard at *Settings → AI → Set Up Local Chat…* walks through `ollama pull gemma4:26b`.

Each wizard mirrors the same three-step flow: install the package manager (Homebrew / uv / Ollama), install the dependency, verify. Live streamed install output, contextual error messages, and a "Skip" option that's always honored.

## Privacy posture

**Private mode is the default.** Everything runs locally — Vision, Surya, Tesseract — and no data leaves your machine. On macOS 26+ with Apple Intelligence enabled, Private mode *also* gets free on-device chapter classification, front-matter metadata extraction, and a coherence pass through Apple's Foundation Models framework — features that previously required Cloud-mode + an Anthropic key.

Cloud features only run when you flip Settings → AI → Processing Mode to Cloud and provide an Anthropic API key (stored in the macOS Keychain). Per-feature toggles let you opt in one at a time; a per-book call cap bounds the worst-case cost. Voyage and Gemini API keys (used for chat embeddings only) are similarly opt-in and per-keychain.

## Build and run

```sh
Scripts/run-app.sh          # release build + assemble .app + sign + open
swift test                  # 1600+ unit tests across 151 test files
```

`Scripts/run-app.sh` is the only supported launch path. `swift run` / `swift build` produce a bare binary without the bundled `Resources/` directory — the editor's CodeMirror source pane and the Surya layout sidecar won't load.

### Cloud-mode setup (optional)

1. Get an Anthropic API key from <https://console.anthropic.com>.
2. Open Settings (⌘,) → **AI → Anthropic API Key** and paste the key. Stored in the macOS Keychain.
3. Switch **Processing Mode** to Cloud and enable the features you want (hard-region OCR, table extraction, post-OCR cleanup, coherence pass, metadata extraction, TOC parsing, semantic classification).
4. Optional: pick a **Page OCR provider** other than the default Claude Sonnet 4.6:
   - **Gemini 2.5 Flash** (GA, recommended for cost) — ~7–10× cheaper per page than Sonnet with comparable quality on typeset prose. Get a Google AI Studio key from <https://aistudio.google.com> and paste it under Settings → AI → Gemini API Key.
   - **Gemini 3 Flash preview** (preview status; subject to API changes) — same key as 2.5 Flash. Newer reasoning model; `thinking_level: minimal` pinned so transcription doesn't pay for unused reasoning.
   - **Gemini 3.5 Flash** (experimental for OCR; stable model released at Google I/O 2026) — same key as 2.5/3 Flash. 3× the per-token cost of 3 Flash Preview but ~50% cheaper than Sonnet. No published document-OCR benchmarks; treat as A/B fodder against the other variants on your corpus before committing to it as default.
   - Manuscript mode always uses Claude Opus 4.7 regardless of this setting.
5. Optional: enable **Google Document OCR in cascade** (Stage 2.5, ~$0.0015/call). Provision a Cloud Vision API key from <https://console.cloud.google.com> (enable the Vision API on the project) and paste it under the same Settings pane.
6. Drop a PDF. The queue row shows a pre-flight cost estimate before the conversion starts; the post-conversion summary shows the per-page refusal rate when non-zero.

Typical cost is pennies to a few dollars per book depending on which features are on and which page-OCR provider you pick. Cost cap and per-feature toggles bound the worst case.

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
│   │   ├── Editor/Chat/             31 files: per-book + library chat (with agentic tool-use loop), BM25 + embedding +
│   │   │                             hierarchy + entity indexes, Topics rollup, alias dictionary, follow-up parser,
│   │   │                             Markdown rendering, retrieval debug, briefing service + persistent store
│   │   ├── Reader/                  Distraction-free reader window — TOC + reading pane + chat sidebar
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
│   └── AI/                          28 files: Anthropic + Ollama + Voyage + Gemini + Apple Foundation Models clients,
│                                    streaming + agentic-loop wire shapes, embedding backends, settings, key stores
├── Tests/                           1600+ unit tests across 151 test files
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
| `Briefings/<sha256>.json` | Per-book cached pre-reading briefing (Markdown + generation timestamp + model identifier). Loaded synchronously on sheet reopen; user-invalidated via the Retry button. |
| `Embeddings/<uuid>.json` | Per-book embedding sidecar — paragraph vectors + hierarchy index + entity index, keyed by library entry UUID. |
| `Covers/<uuid>.jpg` | Per-entry cover override (when the user has replaced the EPUB's bundled cover). |
| `aliases.json` | Per-library alias dictionary for entity retrieval. |
| `library.json` | Library catalog. |
| `snapshots/library-*.json` | Rolling pre-save snapshots of the catalog (20 latest, ≥60 s apart). |
| `queue.json` | Conversion queue snapshot. |

Storing chat / embedding state outside the EPUB keeps the file portable (a copy you give to someone else doesn't carry your chat history) and avoids re-zipping the EPUB on every save.

**When *Share library across machines* is enabled** (Settings → Conversion), `library.json` and `aliases.json` relocate to `<configured output folder>/.humanist/` so a second Mac sharing that folder via iCloud Drive / Dropbox / SyncThing reads the same catalog. Library entries store a `relativePath` from the configured root, so the same JSON resolves correctly even when the absolute root path differs per machine. `Embeddings/`, `Covers/`, `snapshots/`, per-book chat transcripts, and the queue snapshot all stay machine-local — at library scale (tens of GB of embedding sidecars) iCloud Drive's metadata-coordinated reads made every federated-index rebuild a multi-minute stall, so each Mac builds + caches its own indexes from the shared catalog. The catalog also carries an in-flight claim list (`{sourceHash, hostName, claimedAt}`) so two Macs sharing the Input/ folder can't both start converting the same PDF — the second Mac sees the claim and skips.

## Plans

[PLANS.md](PLANS.md) tracks remaining work in detail with a top-of-doc Sequencing section anchoring priorities to current drivers. Shipped this cycle in addition to everything above: **R-Briefing** (per-book pre-reading briefing with embedding-retrieved top-K cross-references against the federated library index, hardened "ONE book is the subject" framing so local models stay book-focused, on-disk caching at `Application Support/Humanist/Briefings/<sha256>.json` with Retry as the explicit invalidator, backend-aware routing through `ChatBackend` so Ollama users get a local briefing without `missingAPIKey`), **R-Chat-Parity** (full chrome parity across editor / library / reader chat surfaces — closed-book briefing glyph, pop-out-to-window, retrieval-detail, export, clear-transcript, all live in all three; chat appearance — font family / size / color scheme — shared via `@AppStorage` keys so a Settings change updates all surfaces without relaunching), **R-Citation-Open-Reader** (citation links from any chat surface force-open in the reader at the cited paragraph anchor regardless of the default-surface picker; reader observes `humanistOpenAtParagraph` and consumes a pending-jump on `load()` so the snap survives a cold book load), **R-Chat-Cross-Corpus Phases 1–3** (`LibraryConceptGraph` rollup over the entity index; Topics sidebar moved to a `sparkles`-style sheet popup behind the toolbar tag button; `Concepts` → `Topics` user-facing rename including the `search_topic` tool wire-name; `search_topic` agentic-loop tool in library chat), **R-Chat-Agentic** (per-book agentic loop with `search_book` / `expand_chapter` / `list_chapter_titles` on Cloud and Ollama; library chat's `search_library` / `search_topic` tools on both; default Ollama model bumped to qwen3.5:9b for tool-call support), **EPUBImporter idempotence fix** (File → Update Library from Output Folder no longer creates `<stem> (2).epub` duplicates when the source already sits at the canonical destination — the suffix-loop is short-circuited via a `base.canonicalForFile == source.canonicalForFile` check), **CLI sidecar lifecycle** (`humanist-cli clear-outdated --backend <choice>` deletes sidecars off the current backend; `humanist-cli reindex --backend <choice>` rebuilds via `BookSidecarBuilder`; both honor `--limit`, dry-run by default for clear-outdated). Older work shipped this cycle: library chat performance (embeddings off iCloud → local disk, on-disk federated-index cache, packed-Float32 binary sidecar format), auto-scan / multi-Mac coordination (source-hash tombstones, in-flight claims to prevent two Macs converting the same PDF, source-hash backfill covering converted PDFs + legacy imports), chapter splitting (TOC-driven splitter with title-matching primary path that survives ambiguous page offsets, ratio-based level-override in the heuristic splitter for Part/Chapter hierarchies), R-Library-Rescan (re-scan an existing catalog row with the launcher's current settings, preserving manual title edits + collection memberships, with `.bak.epub` rollback), queue UX (always-visible Pause/Resume + a "Start paused on launch" preference), the library window's empty-state explainer for collection∩search misses, R-Library-Chat-Plus Tier 2 (citation + conversation export), L-Foundation-Models Phase 2.5 (on-device post-OCR cleanup), R-EPUB-Import coherence pass (text-node-only path), U-HIG-Pass (full Mac HIG / Liquid Glass conformance audit), Q-Hard-Captures Tier 1 (italic-skip, Vision-backfill batch, refused-fallback surface), T-Real-Corpus (`humanist-cli compare-corpus` regression harness), R-Split-Filename-Sanity (bounded chapter-split filename growth), R-Library-Dedupe (content-hash dedupe at import + scan, plus `humanist-cli library-dedupe`), P-Page-Provider-Choice (Gemini 2.5 Flash + Gemini 3 Flash preview alongside Claude Sonnet for page OCR; per-provider key store), P-Doc-OCR-Cascade (Google Cloud Vision `DOCUMENT_TEXT_DETECTION` as Stage 2.5 between Tesseract and Claude), Q-Refusal-Rate (per-page refusal classification — refused / empty / api-error — with provider tag, surfaced in stats panel + claude-pages.txt header), **P-Bundled-Tesseract** (libtesseract + libleptonica + 13 transitive image-format dylibs + eng/grc/lat/heb traineddata bundled inside the .app via weak-linked dylibs with `@rpath` resolution against `Contents/Frameworks/`; app boots even when dylibs are absent thanks to a `dlsym(RTLD_DEFAULT)` runtime gate, so Homebrew is no longer load-bearing for the default OCR path), **P-Bilingual-FacingPage Phase (a)** (Loeb Classical Library style facing-page bilingual detection via Unicode-script ratios for Greek/Hebrew + Latin function-word fingerprint + NLR; each page anchor gets a `data-facing-page` attribute pointing to its partner; per-book *Facing-page bilingual* override in the launcher's Per-job overrides for edge cases), and **R-Reader** (full distraction-free EPUB reader — three-column scene with TOC sidebar + reading pane + chat sidebar; scroll *and* paginated layouts; reading preferences popover with font face / line spacing / margins / theme; per-content-hash position persistence with sub-chapter scroll fraction; bookmarks + highlights + passages-with-notes via a unified `AnnotationStore` sidecar; copy-with-citation at paragraph granularity; right-click context menu with Highlight / Add Note… / Copy with Citation; edit-reader staleness banner when the editor saves over an open book; Library *Reading* column; *Find Missing Files in Library…* maintenance tool that flags missing or unopenable EPUBs with per-row review). Active items:

- **P-Bilingual-FacingPage Phase (b)** — parallel chapter-tree reorganization. With Phase (a) shipped, a confirmed-bilingual book could emit two parallel chapter sequences in one EPUB (original-text spine + translation spine), a dual-tree TOC in nav.xhtml, and a "Jump to Facing Translation" editor command. Ship-or-revise after evaluating Phase (a)'s detected-bilingual rate on real Loeb material.
- **R-Appearance Phase 2** — reader appearance customization on the same `@AppStorage` keys the chat surfaces already use. Inject font-family / font-size / color-scheme CSS into the reader's WKWebView so a single Settings change cascades through every reading surface. Phase 1 (chat) shipped; Phase 2 sketched in PLANS.
- **R-Library-Migrate** — Settings wizard to move library.json + snapshots/ + Covers/ between locations (local ↔ cloud, or cloud → cloud). Embeddings stay local per Mac.
- **R-Content-Aware-Rename** — rename split-chapter EPUBs from first-heading content rather than counter suffixes.
- **L-Foundation-Models Phase 3** — on-device printed-TOC parsing.
- **R-Library-Chat-Plus Tier 2 remainder** — pinned passages, ask-each-book mode.
- **Q-Hard-Captures Tier 2/3** — code-block preservation, layout-aware figure caption snapping, polytonic Greek accuracy lift.
- **Distribution polish** — Developer ID cert, notarization, DMG, GitHub Releases. See [RELEASES.md](RELEASES.md).
- **P-Greek-Quality** — measure Tesseract polytonic-Greek CER against hand-corrected ground truth.

Phase 9 (RTL / Hebrew / Syriac / Coptic) is deferred indefinitely — corpus doesn't justify the bidi-rendering and per-script accuracy lifts.
