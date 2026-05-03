#!/usr/bin/env bash
# Generate AppIcon.icns from BundleAssets/AppIcon-source.png.
#
# macOS .app bundles use Apple's .icns container. The standard build
# pipeline is:
#   1. Resize the source PNG to all required sizes
#   2. Drop them into a `.iconset` directory with Apple's naming convention
#   3. Run `iconutil -c icns` to package them into `.icns`
#
# Re-run this script whenever the source image changes; commit the
# resulting `.icns` so users don't have to regenerate.

source "$(dirname "$0")/_lib.sh"

SRC="$REPO_ROOT/BundleAssets/AppIcon-source.png"
ICONSET_DIR="$REPO_ROOT/BundleAssets/AppIcon.iconset"
OUT_ICNS="$REPO_ROOT/BundleAssets/AppIcon.icns"

[[ -f "$SRC" ]] || die "Missing source image at $SRC"

log "Source:"
sips -g pixelWidth -g pixelHeight "$SRC" | sed 's/^/    /'

# Apple-required size table for macOS app icons.
# Format: <pixel-size> <output-filename>
declare -a SIZES=(
    "16    icon_16x16.png"
    "32    icon_16x16@2x.png"
    "32    icon_32x32.png"
    "64    icon_32x32@2x.png"
    "128   icon_128x128.png"
    "256   icon_128x128@2x.png"
    "256   icon_256x256.png"
    "512   icon_256x256@2x.png"
    "512   icon_512x512.png"
    "1024  icon_512x512@2x.png"
)

log "Building $ICONSET_DIR"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

for entry in "${SIZES[@]}"; do
    set -- $entry
    size="$1"
    name="$2"
    sips -z "$size" "$size" "$SRC" --out "$ICONSET_DIR/$name" >/dev/null 2>&1 \
        || die "Failed to resize to ${size}x${size}"
done

log "Packaging into $OUT_ICNS"
iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"

log "Done. Icon sizes:"
ls -la "$ICONSET_DIR" | tail -10 | sed 's/^/    /'
log "Final .icns: $(du -h "$OUT_ICNS" | cut -f1)"
