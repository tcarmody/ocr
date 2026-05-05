# Phase 3 — PDF Table-of-Contents Parsing

## Goal

When a book's printed table of contents exists in the PDF (most
commercially-published books, virtually all academic monographs),
extract it into structured form, then use it as the authoritative
source for chapter / section / subsection structure. The TOC tells
us what's actually in the book — better than guessing from heading
detection alone.

The win:
- **Hierarchy**: TOCs typically encode a tree (Part → Chapter →
  Section). Heading-detection alone gives us a flat list. The TOC
  is where Part / Chapter / Section relationships live.
- **Authoritative titles**: Surya OCR sometimes mis-reads a heading
  ("Introducfion"); the TOC has the same string and lets us
  cross-correct.
- **Page resolution**: TOCs map titles to *printed* page numbers.
  Combined with our per-page anchors, this gives us a reliable
  "Chapter 3 starts on PDF page N" link.
- **Phase 1 + 2 unlocking**: a TOC tells the chapter splitter
  exactly where chapter boundaries are, even when Surya didn't
  detect the heading on the chapter's first page.

## Scope (what's in / what's out)

In:
- `TOCDetector` — finds the TOC page(s) in a PDF.
- `TOCExtractor` — extracts TOC text from those pages.
- `TOCParser` — parses the extracted text into a structured tree
  via Claude. Falls back to a regex parser when no API key is set.
- `PrintedPageMap` — maps printed page numbers (the TOC's
  references) to PDF page indices (our internal coordinate).
- `TOCAlignedChapterSplitter` — when a parsed TOC is available,
  uses it instead of the heading-based `ChapterSplitter` from
  Phase 1.
- New `Book.toc: ParsedTOC?` field for downstream consumers
  (the editor's nav panel, Phase 2 landmarks).
- Debug log section showing the parsed TOC alongside the heading
  splitter's decisions, so disagreements are visible.

Out (deferred):
- Multi-volume works where the TOC is split across volumes.
- Indexes-as-TOCs (some reference books have a "Contents" + a
  "Detailed Contents" — pick the more granular one).
- Book-club editions where the TOC is in the back.
- Generating a TOC for books that don't have one (lift this from
  Phase 2's chapter list and call it done).

## Architecture

```
PDFIngest/
├── TOCDetector.swift               finds TOC page range
├── TOCExtractor.swift              renders + OCRs the TOC pages
└── PrintedPageMap.swift            printed → PDF page-index resolver

Pipeline/
├── TOCParser.swift                 protocol + RegexTOCParser
├── ClaudeTOCParser.swift           AnthropicAPIClient-backed impl
├── ParsedTOC.swift                 IR: Entry tree
└── TOCAlignedChapterSplitter.swift uses ParsedTOC to drive splitting

Document/
└── Book.swift                       + var toc: ParsedTOC?
```

## End-to-end flow

1. **TOC detection** (`TOCDetector`) — locate the TOC page range.
2. **TOC extraction** (`TOCExtractor`) — render those pages, run
   OCR, return concatenated text.
3. **TOC parsing** (`TOCParser` / `ClaudeTOCParser`) — parse text
   into a structured tree of `Entry` nodes.
4. **Printed-page resolution** (`PrintedPageMap`) — map each
   parsed entry's printed page number to a PDF page index by
   sampling page numbers visible on body pages (we already have a
   page-number heuristic in `HeaderFooterClassifier`).
5. **Chapter splitting** (`TOCAlignedChapterSplitter`) — split the
   reflow output into chapters at PDF-page boundaries the TOC
   identified, using TOC titles instead of OCR'd headings.

When any step fails (no TOC found, parse fails, page resolution
ambiguous), fall back to the Phase 1 heading-based splitter
silently. The user always gets a usable EPUB.

## Step 1 — TOC Detection

Heuristics, in order of preference:

### Heuristic A: PDF outline (free if it exists)

Many PDFs have an embedded outline (`/Outlines` dictionary).
PDFKit exposes this as `PDFDocument.outlineRoot`. When present,
this is the authoritative source — skip OCR-based detection
entirely. (The outline gives us the tree directly; we still need
to resolve outline destinations to PDF page indices, but that's a
PDFKit one-liner.)

### Heuristic B: Page text scan

Walk the first 10% of pages (capped at 30) looking for one whose
embedded or OCR'd text:
- Contains a heading like "Contents", "Table of Contents",
  "Sommaire", "Inhalt", "Indice", etc. (small multilingual list).
- Has many short lines ending with a number (the dotted-leader
  page-number pattern).
- Appears between the title page and the body.

Adjacent pages that share these properties are merged into one
TOC range (some TOCs span 3-4 pages).

### Heuristic C: Layout structure

When we have Surya layout for the candidate pages:
- Heavy concentration of `.text` regions with low height (~3% each)
- Right-aligned numerals at the end of each region
- A `.sectionHeader` reading "Contents" / "Table of Contents" / etc.
  on the first page of the range

Heuristics combine: a page passing all three is a strong TOC.
Outline trumps everything; B alone gets us 80% there.

## Step 2 — TOC Extraction

For OCR-detected TOC pages: render the page (we may already have
done this for the regular pipeline; reuse the cached image),
run Surya OCR (it's better than Vision on column-aligned numbers
and small text), and concatenate the resulting text per region in
reading order.

For PDF-outline TOCs: skip extraction entirely; jump to step 4
with the outline tree as input.

## Step 3 — TOC Parsing

### `RegexTOCParser` (fallback)

Patterns:
```swift
// Numbered with leader dots: "Chapter 3 ........ 47"
#"^(.+?)\s*\.{3,}\s*([ivxlcdm0-9]+)$"#

// Numbered without leaders, tab-separated: "Chapter 3\t47"
#"^(.+?)\s{2,}([ivxlcdm0-9]+)$"#

// Right-aligned column: "Chapter 3" then page number on its own
// or in a separate run/observation. Handled by joining adjacent
// observations on the same line.
```

Hierarchy detection: indentation of leading whitespace.

Brittle on multilingual titles, irregular leader patterns, and
multi-line entries. Acceptable as a fallback.

### `ClaudeTOCParser` (preferred)

Send the extracted TOC text to Claude with a structured prompt:

```
You are parsing a book's table of contents. Return a JSON array
of entries. Each entry has:
  - "title": the section's title as printed
  - "page": the printed page number (string — preserve roman
    numerals as-is)
  - "level": 1 for top-level entries (parts, prefaces, chapters),
    2 for sub-entries (sections within a chapter), 3 for
    sub-sub-entries
  - "type": one of preface / introduction / part / chapter /
    appendix / bibliography / index / notes / glossary / other

Output JSON only, no commentary. If the input doesn't look like a
TOC, output [].

Input:
<TOC text here>
```

Why an LLM is a good fit:
- Handles dotted leaders, tabs, columns, indentation, and
  combinations thereof.
- Recognizes multilingual section types ("Préface", "Vorwort").
- Resolves the hierarchy from indentation + numbering.
- Distinguishes a printed page number from a chapter number
  ("Chapter 3 ... 47" → number=3, page=47).

Cost / latency:
- Claude Haiku 4.5 at $1/MTok input. A typical TOC is ~3KB → ~750
  tokens → ~$0.0008 per book. Output is similarly small.
- Latency: ~1-2 seconds.
- One call per book — not per chapter.

Use a longer-context model (Sonnet) for ~10-page TOCs in reference
books. Configurable in Settings.

### Validation

The parsed JSON is validated:
- All entries have non-empty title and a parseable page number.
- Levels are 1-3 only.
- Types come from the closed set (anything else → "other").
- Pages are monotonically non-decreasing across the entries
  (catches model hallucinations).

Failed validation → log + fall back to regex parser → fall back
to Phase-1 heading splitter.

## Step 4 — Printed-Page Map

`PrintedPageMap` maps printed page number (e.g. "47") to PDF page
index (e.g. 53, because the printed page 47 is the 54th physical
page after frontmatter).

Construction:
- Walk every PDF page's observations.
- For each page, find the page-number-like observation in the
  H/F zone (we already have `HeaderFooterClassifier.isPageNumberLike`).
- Build a `[printedPage: pdfPageIndex]` dictionary.
- Front matter that uses roman numerals is captured as roman → pdf.
- Body matter that switches to arabic gets that mapping.
- Unmatched printed pages: interpolate between known anchors.

Edge cases:
- Pages without a visible page number (often title page, blank
  separators) — gap-fill from neighbors.
- Numbering restarts (some books restart at 1 for each part) —
  detect and segment the map per part.
- Folios (some scholarly editions paginate by folio + recto/verso)
  — leave for later.

## Step 5 — TOC-Aligned Chapter Splitting

`TOCAlignedChapterSplitter.split(blocks:, footnotes:, pageAnchors:,
toc:, pageMap:)` produces chapters keyed off the TOC entries:

For each level-1 TOC entry:
1. Resolve printed page → PDF page index.
2. Find the `Block.anchor` for that PDF page in the block stream.
3. The chapter spans from this anchor up to the next level-1 entry's
   anchor.
4. Title = TOC entry's title (authoritative; overrides Surya OCR).
5. Distribute footnotes and page anchors as in Phase 1.

When a TOC entry's page can't be resolved, skip that entry and use
the heading-based splitter for that range.

Phase 2 / Phase 3 hand off:
- Phase 2's classifier uses TOC entry titles when available
  (better signal than OCR'd headings).
- Phase 2's landmarks gain "Table of Contents" pointing at the
  printed TOC page itself (so readers can jump to the printed
  version via the EPUB nav).

## EPUB output changes

- Per-chapter `epub:type` from TOC entry's "type" (Phase 2 still
  classifies, but the TOC's type wins when both agree; conflict →
  log).
- nav.xhtml's TOC tree mirrors the TOC entry tree (level-1 entries
  in the top `<ol>`, level-2 in nested `<ol>`).
- Landmarks include a `toc` landmark pointing at the printed TOC
  page (as a deep link to its `Block.anchor`).

## Testing

### Unit
- `TOCDetectorTests` — synthetic PDFs with embedded outlines vs
  none; a contents-page-text fixture; verify page-range output.
- `TOCParserTests` — parse golden TOC text fixtures (English,
  French, German, Latin) and assert the resulting tree.
- `PrintedPageMapTests` — observation fixtures with mixed roman /
  arabic page numbers; assert the resolved map matches expected
  PDF indices.
- `TOCAlignedChapterSplitterTests` — synthetic block stream + a
  hand-built ParsedTOC; assert chapter boundaries, titles,
  footnote / anchor distribution.

### Integration
- Convert a book whose TOC we know the structure of (a Penguin
  Classics or Hackett edition with named chapters and a
  bibliography). Verify:
  - The right number of chapters
  - Titles match the printed TOC exactly
  - Each chapter's first PDF page matches the printed TOC's
    page number
  - epubcheck passes

### Snapshot
- Snapshot the resulting `nav.xhtml` for a corpus of test books
  so future changes to the TOC pipeline surface as diffs.

## Risks

1. **No detectable TOC.** Many books, especially scholarly ones,
   have a TOC at the very end (rare) or no TOC at all. Fall back
   silently to Phase 1's heading splitter — already designed for
   this.
2. **Garbled OCR on the TOC page.** TOC pages tend to use small
   text and tight spacing. Run Surya specifically (it's better
   than Vision here), and if confidence is low, fall back to
   regex parsing or heading-based splitting.
3. **Printed-page resolution failure.** When the page-number
   observation isn't visible (page 1 often suppresses its number,
   or the OCR missed it), interpolation should bridge gaps. If
   too many gaps, give up and fall back.
4. **Hallucinated TOC entries.** The LLM occasionally invents
   entries. The validation step catches monotonicity violations
   and impossible levels; reject the parse on validation failure.
5. **PDF outline mismatched with body content.** Some publishers
   embed an outline that doesn't match the printed TOC (e.g. an
   abbreviated outline). When the outline gives us > 200 entries
   for a 200-page book, that's a sign — fall back to text scan.
6. **Cost at scale.** $0.001/book × 1000 books = $1. Trivial.
7. **API key dependency.** Same as Phase 2 — store in Keychain,
   fall back gracefully.

## Phase 2 → 3 dependencies

- Phase 3 needs `Anthropic API key` Settings UI + `Keychain`
  storage from Phase 2. Build Phase 2 first; Phase 3 reuses the
  client + storage.
- Phase 3 supersedes Phase 2's per-chapter classification when a
  TOC is parsed (TOC's "type" field wins). Phase 2's classifier
  still runs as a fallback for chapters not in the TOC (e.g. an
  index that the TOC didn't reference).

## Effort estimate

- ~1 day: TOCDetector (PDFKit outline + text-scan heuristic)
- ~0.5 day: TOCExtractor (reuse render + Surya from main pipeline)
- ~1 day: TOCParser protocol + RegexTOCParser
- ~1 day: ClaudeTOCParser + integration tests against real TOCs
- ~1.5 days: PrintedPageMap (the hardest single-file fix)
- ~1 day: TOCAlignedChapterSplitter
- ~0.5 day: nav.xhtml hierarchical rendering
- ~1 day: end-to-end testing on a corpus of 5-10 books

Total: ~7-8 days for production-quality output.

## Failure-mode hierarchy

The system degrades gracefully:
1. **Best**: PDF outline + Claude TOC parse + complete printed-page
   map → fully-aligned chapters with hierarchy.
2. **Good**: Text-scan TOC + Claude parse + partial page map →
   chapters aligned to TOC but some titles missing.
3. **Acceptable**: TOC found but parse fails / no API key →
   heading-based splitting, no hierarchy. (Phase 1 default.)
4. **Fallback**: No TOC → single chapter or heading-based splitting.
   Same as Phase 1.

The user always gets a valid EPUB. The TOC pipeline only adds
information; it never blocks output.
