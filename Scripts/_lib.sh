#!/usr/bin/env bash
# Shared shell helpers — ported from the Phase 0 spike.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="Humanist"
BUNDLE_ID="com.tcarmody.Humanist"

BUILD_DIR="$REPO_ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"

DEFAULT_CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development}"
CODESIGN_IDENTITY_RESOLVED=""

resolve_signing_identity() {
    if [[ -n "$CODESIGN_IDENTITY_RESOLVED" ]]; then
        return
    fi
    # Force ad-hoc when explicitly requested. Useful when the
    # local Apple Development cert is OCSP-revoked: macOS rejects
    # binaries signed with revoked certs as malware (they have the
    # exact signature of "compromised developer account") but
    # accepts ad-hoc-signed binaries on the same machine without
    # quarantine. Run with `HUMANIST_ADHOC_SIGN=1 ./Scripts/run-app.sh`.
    if [[ "${HUMANIST_ADHOC_SIGN:-0}" == "1" ]] || [[ "$DEFAULT_CODESIGN_IDENTITY" == "-" ]]; then
        CODESIGN_IDENTITY_RESOLVED="-"
        log "Ad-hoc signing (HUMANIST_ADHOC_SIGN set)."
        return
    fi

    # Resolve to a SHA-1 hash, never a name — multiple certs may share a name
    # (e.g. one valid + several revoked), and codesign refuses ambiguous names.
    local listing
    listing="$(security find-identity -v -p codesigning | grep -v "REVOKED")"

    local hash=""
    hash="$(printf '%s\n' "$listing" | { grep "Developer ID Application" || true; } \
        | head -1 | awk '{print $2}')"
    if [[ -z "$hash" ]]; then
        hash="$(printf '%s\n' "$listing" | { grep "$DEFAULT_CODESIGN_IDENTITY" || true; } \
            | head -1 | awk '{print $2}')"
    fi

    if [[ -n "$hash" ]]; then
        CODESIGN_IDENTITY_RESOLVED="$hash"
        local pretty
        pretty="$(printf '%s\n' "$listing" | grep "$hash" | sed 's/^[^"]*"\([^"]*\)".*/\1/')"
        log "Using signing identity: $pretty ($hash)"
    else
        CODESIGN_IDENTITY_RESOLVED="-"
        log "No usable signing identity found — ad-hoc signing only."
    fi
}

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(basename "$0")" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "$(basename "$0")" "$*" >&2; }
die()  { printf '\033[1;31m[%s]\033[0m %s\n' "$(basename "$0")" "$*" >&2; exit 1; }
