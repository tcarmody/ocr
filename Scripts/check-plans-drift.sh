#!/usr/bin/env bash
# Flag PLANS.md items whose status still claims "not started" /
# "planned" / "scoped" / "proposed" but which already have matching
# implementation commits in git history — the recurring drift where a
# feature ships but its PLANS status is never updated.
#
# Heuristic, deliberately lightweight: it pairs each `## Key — …` item
# with its first `**Status**:` line, and for the unstarted-looking ones
# counts non-planning commits whose subject contains the item key (the
# repo's commit convention tags work with the item key, e.g.
# "P-Diagram-Description Tier 1 …"). It will MISS implementation commits
# that never name the key, and is intentionally conservative about which
# statuses count as "unstarted" (it ignores "deferred", which is usually
# an intentional hold). Treat a clean run as "no obvious drift", not a
# proof of perfect sync.
#
# Exit status: 0 = no drift found, 1 = drift found (so it can gate CI or
# a pre-push hook later).
set -euo pipefail

cd "$(dirname "$0")/.."
PLANS="PLANS.md"
[[ -f "$PLANS" ]] || { echo "no $PLANS here" >&2; exit 2; }

# Statuses that mean "work hasn't started". Matched against the start of
# the (lowercased) status text. "deferred" is excluded on purpose.
UNSTARTED_RE='^(planned|proposed|scoped|not started|not yet)'
# Commit subjects that are planning/docs noise, not implementation.
# Lines are "<hash> <subject>", so anchor on the space after the hash
# rather than start-of-line.
PLANNING_RE='( PLANS| docs:|README|[Ss]tash|[Qq]ueue .*item| plan( |$|—|-))'

found_drift=0

# Pair each "## Key — …" header with its first "**Status**:" line.
while IFS=$'\t' read -r key status; do
  short_status="$(printf '%s' "$status" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/^[[:space:]]+//')"
  [[ "$short_status" =~ $UNSTARTED_RE ]] || continue

  # Implementation commits naming this key (key matched literally).
  impl="$(git log --no-merges --format='%h %s' --fixed-strings \
    --grep="$key" | grep -Ev "$PLANNING_RE" || true)"
  [[ -n "$impl" ]] || continue

  found_drift=1
  echo "DRIFT: $key"
  echo "  status:  ${status:0:88}"
  echo "  commits:"
  printf '%s\n' "$impl" | head -4 | sed 's/^/    /'
  echo
done < <(
  awk '
    /^## [A-Za-z0-9]/ { hdr=$2; have=0 }                # key = first token
    /\*\*Status\*\*:/ && hdr!="" && have==0 {
      s=$0; sub(/.*\*\*Status\*\*:[[:space:]]*/,"",s);
      printf "%s\t%s\n", hdr, s; have=1; hdr=""
    }
  ' "$PLANS"
)

if [[ "$found_drift" -eq 0 ]]; then
  echo "check-plans-drift: no obvious drift (unstarted items have no impl commits)."
  exit 0
fi
echo "check-plans-drift: drift found — update the status lines above (with commit refs)." >&2
exit 1
