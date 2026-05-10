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
# `humanist-cli` must be on $PATH. Build it once via:
#
#   swift build --product humanist-cli -c release
#   cp "$(swift build --show-bin-path -c release)/humanist-cli" \
#     ~/.local/bin/humanist-cli
#
# Pass any humanist-cli flags after `--`:
#
#   Scripts/auto-scan-input.sh -- --private --no-claude-tables

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
  echo "auto-scan-input: converting $(basename "$pdf")"
  # humanist-cli's `-o` is a flat output directory — it drops the
  # .epub straight in. Route into Books/ so the in-app library
  # window picks the conversion up automatically. Pass any
  # additional `-f` flags via `--` if you want sibling outputs
  # (md, html, docx, searchable-pdf); they'll all land in Books/
  # too, which differs from the launcher's multi-subfolder routing
  # — pick whichever matches your workflow.
  if humanist-cli convert "$pdf" -o "$BOOKS_DIR" "${CLI_EXTRA_ARGS[@]}"; then
    PROCESSED=$((PROCESSED + 1))
  else
    FAILED=$((FAILED + 1))
    echo "auto-scan-input: failed: $pdf" >&2
  fi
done

echo "auto-scan-input: $PROCESSED converted, $SKIPPED skipped (output already exists), $FAILED failed."
exit 0
