#!/usr/bin/env bash
# Force-rebuild every per-book embedding sidecar against the given
# backend. Equivalent to clicking "Rebuild All Indexes" in the
# Library window's bulk-index sheet, but headless + caffeinate-
# wrapped so the Mac doesn't idle-sleep mid-job.
#
# `humanist-cli reindex --force` ignores existing sidecars and
# rebuilds from scratch — use this when you've changed something
# that affects sidecar shape (new entity extraction, new alias
# dictionary, taxonomy refinement, etc.) and want the change to
# propagate everywhere.
#
# Usage:
#   Scripts/reindex-force.sh <backend>          # all books
#   Scripts/reindex-force.sh <backend> --limit 5  # smoke-test
#
# <backend> ∈ apple | ollama | voyage | gemini
#
# At 444 books × ~3-5s per Gemini call, expect ~20-40 min wall
# time. caffeinate -i keeps the system awake but lets the
# display sleep — fine for a "kick it off and walk away" run.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"

if [[ $# -lt 1 ]]; then
    die "usage: $0 <backend> [extra humanist-cli flags]"
fi
BACKEND="$1"
shift

log "Building humanist-cli (release)…"
swift build --product humanist-cli -c release
BIN="$(swift build --product humanist-cli -c release --show-bin-path)/humanist-cli"
[[ -x "$BIN" ]] || die "humanist-cli not found at $BIN"

log "Force-rebuilding all sidecars against backend=$BACKEND"
log "Wrapped in caffeinate -i — system stays awake; display can sleep."
exec caffeinate -i "$BIN" reindex --backend "$BACKEND" --force "$@"
