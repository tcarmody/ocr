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

log "Signing"
resolve_signing_identity
ENTITLEMENTS="$REPO_ROOT/BundleAssets/$APP_NAME.entitlements"

SIGN_OPTS=(--force --options runtime --timestamp --sign "$CODESIGN_IDENTITY_RESOLVED")
if [[ "$CODESIGN_IDENTITY_RESOLVED" == "-" ]]; then
    SIGN_OPTS=(--force --options runtime --sign -)
fi

codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$APP_MACOS/$APP_NAME"
codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

log "Verifying"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/    /'

log "Bundle:"
du -sh "$APP_BUNDLE"
log "Done."
