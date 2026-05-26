#!/usr/bin/env bash
# Walk the catalog and rebuild each book's per-paragraph entity
# index from the current alias dictionary + AFM-extracted
# concepts, WITHOUT re-embedding paragraphs. The Topics view
# refreshes against the new vocabulary on next open.
#
# When to use this instead of reindex-force.sh:
#   * You edited the alias dictionary and want existing books
#     to pick up the new terms.
#   * You ran the in-app bulk concept extraction but want to
#     re-fold the saved concepts into the entity indexes
#     without paying the cloud-embedding round-trip again.
#   * You're on a cloud embedding backend (Gemini / Voyage)
#     and want to refresh Topics for free instead of burning
#     embedding budget.
#
# Cost shape: ~1-3s per book (CPU-only NLTagger work) vs.
# ~2-5s per book for a full cloud reindex. On a 444-book
# library that's roughly 10 minutes vs. 30+ minutes.
#
# Usage:
#   Scripts/refresh-entity-index.sh             # all books
#   Scripts/refresh-entity-index.sh --limit 5   # smoke-test
#
# Backend doesn't matter here — entity-index rebuilds use
# NLTagger locally and don't touch the embedding API. The
# script doesn't take a <backend> argument.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_lib.sh"

log "Building humanist-cli (release)…"
swift build --product humanist-cli -c release
BIN="$(swift build --product humanist-cli -c release --show-bin-path)/humanist-cli"
[[ -x "$BIN" ]] || die "humanist-cli not found at $BIN"

log "Refreshing entity indexes (no embeddings touched)"
log "Wrapped in caffeinate -i — system stays awake; display can sleep."
exec caffeinate -i "$BIN" refresh-entity-index "$@"
