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

# Backend resolution:
#   1. Explicit positional arg ($1) wins ($0 gemini → --backend gemini).
#   2. Otherwise read humanist.chat.embeddingBackend from the app's
#      UserDefaults — same key Settings → AI → Chat Retrieval writes —
#      and translate from the Swift enum's rawValue to the CLI's
#      --backend token (appleNL → apple; others are 1:1).
#   3. If neither is set, fail with a usage hint that names the options.
if [[ $# -ge 1 && "$1" =~ ^(apple|ollama|voyage|gemini)$ ]]; then
    BACKEND="$1"
    shift
else
    RAW="$(defaults read "$BUNDLE_ID" humanist.chat.embeddingBackend 2>/dev/null || true)"
    case "$RAW" in
        appleNL) BACKEND="apple" ;;
        ollama|voyage|gemini) BACKEND="$RAW" ;;
        "")
            die "no backend configured. Pass one explicitly: $0 <apple|ollama|voyage|gemini>"
            ;;
        *)
            die "unrecognized backend '$RAW' in Settings. Pass explicitly: $0 <apple|ollama|voyage|gemini>"
            ;;
    esac
    log "Backend resolved from Settings → AI → Chat Retrieval: $BACKEND"
fi

log "Building humanist-cli (release)…"
swift build --product humanist-cli -c release
BIN="$(swift build --product humanist-cli -c release --show-bin-path)/humanist-cli"
[[ -x "$BIN" ]] || die "humanist-cli not found at $BIN"

log "Force-rebuilding all sidecars against backend=$BACKEND"
log "Wrapped in caffeinate -i — system stays awake; display can sleep."
exec caffeinate -i "$BIN" reindex --backend "$BACKEND" --force "$@"
