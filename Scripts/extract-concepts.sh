#!/usr/bin/env bash
# Walk the catalog and run AFM concept extraction on each book.
# Per-book payload persists to <library state dir>/Concepts/, the
# embedding sidecar's entity index gets rebuilt in the same pass
# so the new concepts surface in the Topics view on next sheet
# open.
#
# Usage:
#   Scripts/extract-concepts.sh                 # only books without an existing payload
#   Scripts/extract-concepts.sh --force         # re-extract every book
#   Scripts/extract-concepts.sh --limit 5       # smoke-test
#   Scripts/extract-concepts.sh --force --limit 5
#
# When to use --force:
#   * After a BookConceptExtractor prompt revision (modelIdentifier
#     bumps from afm-on-device-1 to afm-on-device-2) — existing
#     payloads carry old prompt output; --force re-extracts with
#     the new prompt.
#   * After editing the alias dictionary if you want the entity
#     indexes refreshed alongside extraction (use
#     refresh-entity-index.sh if you only want the entity rebuild).
#
# Cost: ~5-10s AFM + ~1-3s entity rebuild per book = ~10s
# average. A 444-book --force run takes ~75 min. Wrapped in
# caffeinate -i so the Mac doesn't idle-sleep mid-job.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"

log "Building humanist-cli (release)…"
swift build --product humanist-cli -c release
BIN="$(swift build --product humanist-cli -c release --show-bin-path)/humanist-cli"
[[ -x "$BIN" ]] || die "humanist-cli not found at $BIN"

log "Extracting concepts (caffeinate -i — system stays awake; display can sleep)"
exec caffeinate -i "$BIN" extract-concepts "$@"
