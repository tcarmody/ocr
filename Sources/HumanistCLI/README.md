# humanist-cli

Command-line interface to the Humanist conversion pipeline. Same engines
as the SwiftUI app — Vision OCR, Surya layout, optional Tesseract / Claude,
EPUB writers, sibling outputs — exposed as a single binary so conversions
can run in scripts, CI, and shell pipelines.

## Build

```sh
swift build --product humanist-cli -c release
# Binary at .build/release/humanist-cli
```

Drop the binary anywhere on `$PATH`:

```sh
cp .build/release/humanist-cli ~/.local/bin/humanist-cli
```

## Subcommands

```
humanist-cli convert  <input> [options]   Convert a file to EPUB/MD/HTML/DOCX/TXT/searchable-PDF
humanist-cli compare  <left> <right>      Diff two EPUBs at chapter/paragraph level
humanist-cli validate <epub>              Run epubcheck and report issues
```

`convert` is the default subcommand — `humanist-cli book.pdf` is the same as `humanist-cli convert book.pdf`.

## Convert

### Inputs

`pdf` · `txt` · `md` · `markdown` · `rtf` · `html` · `htm` · `docx` · `doc` · `odt`

PDF inputs run through the full OCR pipeline (Vision → Surya → Tesseract → optional Claude, plus layout analysis, chapter splitting, and figure/table extraction). Other inputs go through `DocumentIngest`, which extracts paragraphs, headings, and inline emphasis without running OCR.

### Outputs (`-f` / `--formats`)

| Format | Description |
|---|---|
| `epub` | EPUB 3 with full nav, figures, tables, footnotes (default) |
| `md` | GitHub-flavored Markdown with footnote definitions |
| `txt` | Plain text — no markup |
| `html` | Self-contained HTML5 with inline CSS |
| `docx` | Microsoft Word OOXML |
| `searchable-pdf` | Source PDF with invisible OCR text overlay (PDF input only) |

Comma-separate or repeat `-f`:

```sh
humanist-cli book.pdf -f epub,md,html
humanist-cli book.pdf -f epub -f md -f html
```

### Examples

```sh
# Default: write book.epub next to book.pdf
humanist-cli convert book.pdf

# Markdown only, no EPUB
humanist-cli convert paper.pdf -f md

# Everything, into ./out/
humanist-cli convert book.pdf -f epub,md,html,docx,searchable-pdf -o ./out

# A/B compare two settings — same input, different outputs
humanist-cli convert book.pdf --output-suffix local
humanist-cli convert book.pdf --output-suffix claude --claude-page-ocr
humanist-cli compare "book local.epub" "book claude.epub"

# DOCX → Markdown (no OCR, no EPUB)
humanist-cli convert paper.docx -f md

# Force OCR on a specific page range
humanist-cli convert mixed.pdf --force-ocr-pages "1-20,150-160"

# Use Surya for high-accuracy local OCR
humanist-cli convert greek.pdf --surya -l grc

# Cloud-mode features individually
humanist-cli convert book.pdf --no-claude-tables --no-coherence-pass

# Force Private mode (disable every Cloud feature, even with API key set)
humanist-cli convert book.pdf --private
```

### Cloud-mode setup

Cloud features (Claude OCR, table extraction, post-OCR cleanup, TOC parsing, semantic classification, coherence pass, metadata extraction) are on by default whenever `--private` isn't set. Each can be disabled individually with `--no-<feature>`.

The Anthropic API key is read from `ANTHROPIC_API_KEY` by default. Override the env var name with `--api-key-env MY_VAR`.

### Output naming

```
[output-dir]/[output-name OR input-stem][ output-suffix].[ext]
```

- `--output-dir DIR` — defaults to the input file's directory
- `--output-name NAME` — defaults to the input's basename (without ext)
- `--output-suffix STR` — appended with a leading space, e.g. `book claude.epub`

### Logging modes

| Flag | Effect |
|---|---|
| (default) | Single-line live progress on TTY; line-by-line elsewhere |
| `-q` / `--quiet` | Errors only |
| `-v` / `--verbose` | Per-page detail |
| `--json` | Newline-delimited JSON events on stdout |

## Compare

```sh
humanist-cli compare old.epub new.epub
humanist-cli compare old.epub new.epub -o report.diff.txt
humanist-cli compare old.epub new.epub --summary-only
```

Exit code 0 when the EPUBs are identical at the paragraph level, 1 when they differ. Useful in CI to gate "did this conversion change?" checks.

## Validate

```sh
humanist-cli validate book.epub
humanist-cli validate book.epub --errors-only
humanist-cli validate book.epub --json
```

Wraps `epubcheck` (`brew install epubcheck` first). Exit codes:

- `0` — passed (no FATAL or ERROR messages)
- `1` — failed validation
- `2` — `epubcheck` not installed

## Dependencies

The CLI inherits the same external dependencies as the SwiftUI app, with the same setup model — install when you need them, skip when you don't:

- **Surya** (optional) — `uv tool install surya-ocr`. Without it, the cascade falls back to Vision-only.
- **Tesseract** (optional) — `brew install tesseract tesseract-lang`. Without it, the classical-script tier of the cascade is unavailable.
- **epubcheck** (optional) — `brew install epubcheck`. Required for `humanist-cli validate`.
- **Anthropic API key** (optional) — set `ANTHROPIC_API_KEY` for Cloud features.
