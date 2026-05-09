#!/usr/bin/env bash
# Build the SwiftUI app and assemble + sign the .app bundle.
# Mirrors the spike's structure. No nested Mach-Os yet, so signing is just
# the main executable + the bundle.

source "$(dirname "$0")/_lib.sh"

log "Cleaning old bundle"
rm -rf "$APP_BUNDLE"

log "Compiling Swift executable (release, arm64)"
( cd "$REPO_ROOT" && swift build -c release --arch arm64 )

BIN="$REPO_ROOT/.build/arm64-apple-macosx/release/$APP_NAME"
[[ -x "$BIN" ]] || die "Swift build did not produce $BIN"

log "Assembling $APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BIN" "$APP_MACOS/$APP_NAME"
cp "$REPO_ROOT/BundleAssets/Info.plist" "$APP_CONTENTS/Info.plist"

ICON_ICNS="$REPO_ROOT/BundleAssets/AppIcon.icns"
if [[ -f "$ICON_ICNS" ]]; then
    cp "$ICON_ICNS" "$APP_RESOURCES/AppIcon.icns"
    log "Copied AppIcon.icns into bundle Resources"
else
    warn "AppIcon.icns not found at $ICON_ICNS — bundle will use default icon"
fi

# Phase 4: bundle the layout sidecar Python script. The runtime
# (surya-ocr installed via uv) is found by absolute path on the user's
# system; only our script lives inside the .app for now. Phase 4.6
# will bundle the runtime + weights too so the app distributes
# self-contained.
LAYOUT_SIDECAR="$REPO_ROOT/Sidecars/layout/sidecar.py"
if [[ -f "$LAYOUT_SIDECAR" ]]; then
    mkdir -p "$APP_RESOURCES/layout-sidecar"
    cp "$LAYOUT_SIDECAR" "$APP_RESOURCES/layout-sidecar/sidecar.py"
    log "Copied layout sidecar into bundle Resources"
fi

# CodeMirror source editor (Phase 7.E). Vendor the JS/CSS/host page
# so the editor works offline and we don't depend on a CDN at runtime.
CODEMIRROR_DIR="$REPO_ROOT/Resources/codemirror"
if [[ -d "$CODEMIRROR_DIR" ]]; then
    cp -R "$CODEMIRROR_DIR" "$APP_RESOURCES/codemirror"
    log "Copied CodeMirror into bundle Resources"
else
    warn "CodeMirror assets not found at $CODEMIRROR_DIR — source editor will fall back to plain text"
fi

# Pin to the developer's Developer ID Application certificate by
# SHA-1 hash. Hash is unambiguous — name-based selection breaks when
# the keychain has multiple certs of the same name (e.g. one valid +
# one revoked). resolve_signing_identity short-circuits when
# CODESIGN_IDENTITY_RESOLVED is already set, so this becomes the active
# identity for signed builds. HUMANIST_ADHOC_SIGN=1 still wins —
# leaving RESOLVED empty lets the resolver's ad-hoc branch fire.
if [[ "${HUMANIST_ADHOC_SIGN:-0}" != "1" ]]; then
    CODESIGN_IDENTITY_RESOLVED="21F5CB1F4F74DFC9D58BD2D3C454E9B2F0C716A2"
    log "Pinned signing identity: $CODESIGN_IDENTITY_RESOLVED (Developer ID Application)"
fi

log "Signing"
resolve_signing_identity
ENTITLEMENTS="$REPO_ROOT/BundleAssets/$APP_NAME.entitlements"

# Notarization-ready flags:
#   --options runtime  — hardened runtime; required for notarization.
#   --timestamp        — Apple secure timestamp; required for notarization.
#                        Omitted in the ad-hoc path because timestamping
#                        needs a valid Apple identity.
#   --deep             — recursively sign nested bundles. We don't have
#                        any today, but matches the --deep used in the
#                        verify pass below and stays correct if Resources/
#                        ever gains a Mach-O.
SIGN_OPTS=(--force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY_RESOLVED")
if [[ "$CODESIGN_IDENTITY_RESOLVED" == "-" ]]; then
    SIGN_OPTS=(--force --deep --options runtime --sign -)
fi

codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$APP_MACOS/$APP_NAME"
codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

log "Verifying"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/    /'

log "Bundle:"
du -sh "$APP_BUNDLE"
log "Done."
