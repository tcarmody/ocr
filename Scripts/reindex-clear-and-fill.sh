#!/usr/bin/env bash
# Two-step library-index refresh:
#   1. Clear every sidecar whose backend doesn't match the
#      requested one (`humanist-cli clear-outdated --apply`).
#   2. Build / re-build any sidecar that's missing OR was just
#      cleared by step 1 (`humanist-cli reindex`, no --force, so
#      books already on the right backend skip cheaply).
#
# Use case: you switched embedding backends (Apple NL → Gemini, or
# Voyage → Gemini, etc.) and want every book on the new vector
# space, without paying the full force-rebuild cost on books that
# happened to already be on the right backend.
#
# Differences from reindex-force.sh:
#   * Doesn't touch sidecars that already match the requested
#     backend (cheap pass-through).
#   * Drops stale sidecars from prior backends so they don't sit
#     around using disk + confusing the federated index.
#   * Same caffeinate -i wrapper.
#
# Usage:
#   Scripts/reindex-clear-and-fill.sh <backend>          # everything
#   Scripts/reindex-clear-and-fill.sh <backend> --limit 5  # smoke-test
#
# <backend> ∈ apple | ollama | voyage | gemini

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"

# Backend resolution mirrors reindex-force.sh: explicit positional
# arg wins; falls back to the app's configured chat embedding
# backend (Settings → AI → Chat Retrieval); errors out with a
# usage hint when neither is set.
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

log "Step 1/2: clearing sidecars not on backend=$BACKEND"
# --apply makes clear-outdated actually delete; without it the
# command is a dry-run report.
caffeinate -i "$BIN" clear-outdated --backend "$BACKEND" --apply

log "Step 2/2: building missing sidecars on backend=$BACKEND"
exec caffeinate -i "$BIN" reindex --backend "$BACKEND" "$@"
