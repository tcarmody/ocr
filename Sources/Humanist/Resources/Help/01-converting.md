# Converting documents into EPUB

Humanist accepts PDFs, Word documents, RTF, HTML, ODT, plain text, Markdown, and existing EPUBs (the last gets imported into the library without re-OCR).

## Three ways to start a conversion

- **Drag-drop onto the launcher** — files or whole folders. Folders walk recursively.
- **File → Open** (⌘O) — single file picker.
- **Auto-scan** — Settings → Conversion → Auto-scan Input folder. Anything dropped into `<output folder>/Input/` while the launcher runs is enqueued with the current defaults. `Scripts/auto-scan-input.sh` is the headless companion for cron.

The queue (⌘4) shows progress per job; Pause/Resume is always visible in the launcher toolbar.

## Conversion modes (per job)

The launcher's *Per-job overrides* lets you pick the mode for each PDF:

- **Print** — typeset books, born-digital or scanned. The default.
- **Early Print** — 15th–18th c. printed books. Silently modernizes long-s, u/v, i/j, ligatures. Preserves period spelling. Handles Roman, Blackletter (Fraktur), and Italic typefaces.
- **Manuscript** — handwritten material. Uses Claude Opus 4.7 (provider-pinned — handwriting needs Opus's visual reasoning). Hand-family prompts for 16th–17th c. secretary, 18th c. round hand, 19th–early 20th c. cursive, modern.
- **Facing-page bilingual** — Loeb-style facing-page editions. Tags each page anchor with its partner via `data-facing-page`. Auto-detect is conservative; this toggle relaxes the gates.

## Private vs. Cloud

**Private mode is the default** — Vision, Surya, Tesseract, and (on macOS 26+) Apple's Foundation Models do everything on-device. Nothing leaves your machine.

**Cloud features are individually opt-in** under Settings → AI:

- **Hard-region OCR** (Claude Sonnet) — the residual that Vision/Surya/Tesseract couldn't read
- **Google Document OCR** ($0.0015/call) — Stage 2.5 between Tesseract and Claude
- **Table extraction** — Claude Sonnet handles complex tables Surya can't
- **Post-OCR cleanup** (Haiku) — fixes ligatures, missing diacritics, long-s on low-quality regions
- **Printed TOC parsing** — one Haiku call extracts the printed table of contents
- **Semantic classification** — `epub:type` labels per chapter
- **Coherence pass** — recurring OCR-error fixups across all chapters
- **Metadata extraction** — title / author / year / publisher / ISBN from front matter
- **Whole-page OCR** — bypass the per-region cascade entirely; one call per page

For whole-page OCR, pick a provider:

| Provider | Cost/page | Notes |
|---|---|---|
| Claude Sonnet 4.6 | ~$0.04 | Best on dense academic layouts (baseline) |
| Gemini 2.5 Flash | ~$0.005 | GA; ~7–10× cheaper than Sonnet on typeset prose |
| Gemini 3 Flash preview | ~$0.006 | Newer reasoning model; `thinking_level: minimal` pinned |
| Gemini 3.5 Flash | ~$0.02 | Experimental for OCR; ~half Sonnet's cost |

## Cost control

A **pre-flight cost estimate** appears on each queue row before the conversion starts — projected Claude calls and dollars based on page count + which features are on.

A **per-book cost cap** (Settings → AI → Cost cap) bounds the worst case — set it to e.g. $5 and the pipeline aborts the book if it would exceed.

The **post-conversion summary** surfaces a **per-page refusal rate** when non-zero — so policy refusals don't silently degrade quality.

## What you get

Every conversion produces six sibling files:

- `<basename>.epub` — primary output
- `<basename>.txt` — plain text
- `<basename>.md` — Markdown
- `<basename>.html` — self-contained HTML
- `<basename>.docx` — Word OOXML
- `<basename>.searchable.pdf` — your source PDF with an invisible OCR text overlay; Cmd+F searchable, visually identical

The launcher splits these into two toggles: **`.txt + .md`** (on by default) and **`.html + .docx`** (off by default). All siblings stay in sync when you save edits in the editor.
