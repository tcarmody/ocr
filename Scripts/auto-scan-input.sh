#!/usr/bin/env bash
# Auto-scan companion script. Walks `<outputRoot>/Input/` for PDFs
# that don't yet have a corresponding `<outputRoot>/Books/<stem>.epub`
# and converts each one via `humanist-cli convert`. Outputs land in
# the usual per-format subfolders under the configured root, same
# as a drag-drop conversion through the launcher.
#
# This is the headless alternative to the in-app watcher: if you're
# running the app and have "Automatically scan Input folder for new
# PDFs" toggled on in Settings → Conversion, you don't need this
# script — the launcher does the same thing. Use this if you want
# scans to run from cron, launchd, or a headless build server.
#
# Usage:
#
#   Scripts/auto-scan-input.sh           # uses Settings → Conversion's root
#   Scripts/auto-scan-input.sh /path     # explicit root override
#
# The script reads Humanist's configured output root from the same
# UserDefaults key the app uses
# (`humanist.conversion.outputFolderPath`), so unless you pass a
# path explicitly, the script honors what's set in Settings →
# Conversion → Output folder.
#
# Conversion defaults — Surya / Claude OCR, Force OCR, Private
# mode, debug log, sibling formats — are also read from the
# `humanist.conversion.default*` UserDefaults set by Settings →
# Conversion → Conversion defaults. The script translates each
# default to the matching humanist-cli flag. Any extra flags
# passed after `--` win — the script appends them last so user
# overrides take precedence.
#
# `humanist-cli` must be on $PATH. Build it once via:
#
#   swift build --product humanist-cli -c release
#   cp "$(swift build --show-bin-path -c release)/humanist-cli" \
#     ~/.local/bin/humanist-cli
#
# Pass any extra humanist-cli flags after `--`:
#
#   Scripts/auto-scan-input.sh -- --no-claude-tables -l grc
#
# To temporarily override a Settings default, just pass the
# explicit flag after `--`: e.g. `-- --private` to force Private
# mode for this run regardless of the Settings toggle.

set -euo pipefail

BUNDLE_ID="${HUMANIST_BUNDLE_ID:-com.humanist.macos}"

# Resolve the output root. Explicit arg wins; otherwise read from
# the app's preferences. macOS stores `@AppStorage` values under
# the bundle id's defaults domain.
if [[ $# -gt 0 && "$1" != "--" ]]; then
  OUTPUT_ROOT="$1"
  shift
else
  if ! OUTPUT_ROOT=$(defaults read "$BUNDLE_ID" humanist.conversion.outputFolderPath 2>/dev/null); then
    echo "auto-scan-input: no output folder configured in Settings → Conversion." >&2
    echo "auto-scan-input: pass a path explicitly: Scripts/auto-scan-input.sh /path/to/root" >&2
    exit 1
  fi
fi

# Discard a `--` separator so users can pass humanist-cli flags
# after the path arg (`./auto-scan-input.sh /path -- --private`).
if [[ $# -gt 0 && "$1" == "--" ]]; then
  shift
fi
CLI_EXTRA_ARGS=("$@")

# Read a Bool default from the app's UserDefaults. Falls back to
# the second arg when the key isn't set. macOS's `defaults read`
# prints 1/0 for booleans; treat anything that isn't an exact "1"
# as false.
read_bool_default() {
  local key="$1"
  local fallback="$2"
  local raw
  if raw=$(defaults read "$BUNDLE_ID" "$key" 2>/dev/null); then
    [[ "$raw" == "1" ]] && echo "true" || echo "false"
  else
    echo "$fallback"
  fi
}

DEFAULT_SURYA=$(read_bool_default humanist.conversion.defaultUseSuryaOCR false)
DEFAULT_CLAUDE_PAGE=$(read_bool_default humanist.conversion.defaultUseClaudePageOCR false)
DEFAULT_FORCE_OCR=$(read_bool_default humanist.conversion.defaultForceOCR false)
DEFAULT_PRIVATE=$(read_bool_default humanist.conversion.defaultPrivateMode false)
DEFAULT_DEBUG=$(read_bool_default humanist.conversion.defaultEmitDebugLog false)
DEFAULT_TEXT_SIBLINGS=$(read_bool_default humanist.conversion.defaultEmitSiblingTextOutputs true)
DEFAULT_DOC_SIBLINGS=$(read_bool_default humanist.conversion.defaultEmitSiblingDocuments false)
DEFAULT_SEARCHABLE_PDF=$(read_bool_default humanist.conversion.defaultEmitSearchablePDF false)

# Compose the format list from the sibling toggles. EPUB is always
# in; the txt/md, html/docx, and searchable-pdf groups follow the
# same pairing the launcher uses.
FORMATS="epub"
[[ "$DEFAULT_TEXT_SIBLINGS" == "true" ]] && FORMATS="$FORMATS,md,txt"
[[ "$DEFAULT_DOC_SIBLINGS"  == "true" ]] && FORMATS="$FORMATS,html,docx"
[[ "$DEFAULT_SEARCHABLE_PDF" == "true" ]] && FORMATS="$FORMATS,searchable-pdf"

# Translate the remaining boolean defaults into humanist-cli flags.
# Built into an array so word-splitting doesn't break paths with
# spaces (none of these flags carry values, but defensive shape).
DEFAULT_FLAGS=()
[[ "$DEFAULT_SURYA"       == "true" ]] && DEFAULT_FLAGS+=("--surya")
[[ "$DEFAULT_CLAUDE_PAGE" == "true" ]] && DEFAULT_FLAGS+=("--claude-page-ocr")
[[ "$DEFAULT_FORCE_OCR"   == "true" ]] && DEFAULT_FLAGS+=("--force-ocr")
[[ "$DEFAULT_PRIVATE"     == "true" ]] && DEFAULT_FLAGS+=("--private")
[[ "$DEFAULT_DEBUG"       == "true" ]] && DEFAULT_FLAGS+=("--debug")

INPUT_DIR="$OUTPUT_ROOT/Input"
BOOKS_DIR="$OUTPUT_ROOT/Books"

if [[ ! -d "$INPUT_DIR" ]]; then
  echo "auto-scan-input: creating $INPUT_DIR"
  mkdir -p "$INPUT_DIR"
fi
mkdir -p "$BOOKS_DIR"

if ! command -v humanist-cli >/dev/null 2>&1; then
  echo "auto-scan-input: humanist-cli not found on PATH." >&2
  echo "auto-scan-input: install via:" >&2
  echo "  swift build --product humanist-cli -c release" >&2
  echo "  cp \"\$(swift build --show-bin-path -c release)/humanist-cli\" ~/.local/bin/" >&2
  exit 2
fi

shopt -s nullglob
PROCESSED=0
SKIPPED=0
FAILED=0

# Sort alphabetically so the convert order is deterministic when
# the user dropped several PDFs at once.
for pdf in "$INPUT_DIR"/*.pdf "$INPUT_DIR"/*.PDF; do
  stem="$(basename "$pdf" | sed -E 's/\.[Pp][Dd][Ff]$//')"
  expected_epub="$BOOKS_DIR/${stem}.epub"
  if [[ -f "$expected_epub" ]]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  echo "auto-scan-input: converting $(basename "$pdf") (formats: $FORMATS)"
  # humanist-cli's `-o` is a flat output directory — it drops the
  # .epub (and any other requested formats) straight in. Route
  # everything into Books/ so the in-app library window picks the
  # conversion up automatically. The launcher splits by subfolder
  # (Books/, Searchable PDFs/, Text Files/, etc.) but the CLI
  # doesn't — known divergence. Defaults from Settings turn into
  # `--surya` / `--claude-page-ocr` / `--force-ocr` / `--private` /
  # `--debug` flags and a composed `-f epub,md,txt,…` list. User
  # `-- …` flags append last so they win over the defaults.
  # Defensive empty-array expansion — bash 3.2.57 (the macOS
  # system bash) treats `"${arr[@]}"` of an empty array as unbound
  # under `set -u`. The `${arr[@]+…}` form expands to nothing when
  # the array is empty and to the elements when it's not.
  if humanist-cli convert "$pdf" \
      -o "$BOOKS_DIR" \
      -f "$FORMATS" \
      ${DEFAULT_FLAGS[@]+"${DEFAULT_FLAGS[@]}"} \
      ${CLI_EXTRA_ARGS[@]+"${CLI_EXTRA_ARGS[@]}"}; then
    PROCESSED=$((PROCESSED + 1))
  else
    FAILED=$((FAILED + 1))
    echo "auto-scan-input: failed: $pdf" >&2
  fi
done

echo "auto-scan-input: $PROCESSED converted, $SKIPPED skipped (output already exists), $FAILED failed."
exit 0
