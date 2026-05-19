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

# Credits.rtf — picked up automatically by NSApplication's standard
# About panel. No code change required to surface it. Lists
# attribution for Surya, Tesseract, CodeMirror, epubcheck, etc.
CREDITS_RTF="$REPO_ROOT/BundleAssets/Credits.rtf"
if [[ -f "$CREDITS_RTF" ]]; then
    cp "$CREDITS_RTF" "$APP_RESOURCES/Credits.rtf"
    log "Copied Credits.rtf into bundle Resources"
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

# Bundle Tesseract + Leptonica + transitive image-format dylibs into
# Contents/Frameworks/ so the app works on Macs without Homebrew.
# Source-of-truth lookup chain is /opt/homebrew/opt/<pkg>/lib/ first
# (real binaries — symlinks at /opt/homebrew/lib/ resolve here), then
# /opt/homebrew/lib/ as a fallback. The list mirrors what `otool -L`
# walks transitively from libtesseract/libleptonica; if any dylib is
# missing we abort the bundle step rather than ship a half-bundled
# .app that would crash on real-world content (libtiff being absent
# wouldn't fail on a simple eng-only page but would on a JPEG-in-TIFF
# scan).
#
# Each dylib has its LC_ID_DYLIB and every LC_LOAD_DYLIB referencing
# another bundled dylib rewritten to `@rpath/libfoo.N.dylib` via
# install_name_tool. The main binary's LC_LOAD_DYLIB entries for the
# weak-linked tesseract/leptonica are rewritten the same way, and an
# LC_RPATH of `@executable_path/../Frameworks` is added so dyld
# resolves the @rpath references against the bundled copies.
log "Bundling Tesseract + Leptonica + transitive dylibs"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
mkdir -p "$APP_FRAMEWORKS"

# Map of pkg-path → dylib basename. Each entry is what otool reports
# when walking transitively from libtesseract / libleptonica. Order
# doesn't matter for copying but is preserved for log readability.
DYLIB_SOURCES=(
    "/opt/homebrew/opt/tesseract/lib/libtesseract.5.dylib"
    "/opt/homebrew/opt/leptonica/lib/libleptonica.6.dylib"
    "/opt/homebrew/opt/libarchive/lib/libarchive.13.dylib"
    "/opt/homebrew/opt/libpng/lib/libpng16.16.dylib"
    "/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib"
    "/opt/homebrew/opt/giflib/lib/libgif.dylib"
    "/opt/homebrew/opt/libtiff/lib/libtiff.6.dylib"
    "/opt/homebrew/opt/webp/lib/libwebp.7.dylib"
    "/opt/homebrew/opt/webp/lib/libwebpmux.3.dylib"
    "/opt/homebrew/opt/webp/lib/libsharpyuv.0.dylib"
    "/opt/homebrew/opt/openjpeg/lib/libopenjp2.7.dylib"
    "/opt/homebrew/opt/zstd/lib/libzstd.1.dylib"
    "/opt/homebrew/opt/xz/lib/liblzma.5.dylib"
    "/opt/homebrew/opt/lz4/lib/liblz4.1.dylib"
    "/opt/homebrew/opt/libb2/lib/libb2.1.dylib"
)

for src in "${DYLIB_SOURCES[@]}"; do
    if [[ ! -f "$src" ]]; then
        die "Missing source dylib: $src — run \`brew install tesseract\` first"
    fi
    base="$(basename "$src")"
    # Copy with -L to dereference symlinks (brew exposes versioned
    # names via symlinks pointing at the real binary).
    cp -L "$src" "$APP_FRAMEWORKS/$base"
    chmod +w "$APP_FRAMEWORKS/$base"
done
log "Copied $(echo "${DYLIB_SOURCES[@]}" | wc -w | tr -d ' ') dylibs into Frameworks/"

# Rewrite install names. For each bundled dylib:
#   1. Set its own LC_ID_DYLIB to `@rpath/<basename>`.
#   2. For each LC_LOAD_DYLIB referencing another bundled dylib
#      (whether by absolute /opt/homebrew/... path or by @rpath/...),
#      rewrite it to `@rpath/<that basename>`.
# Building the "bundled set" first so we can match by basename in
# step 2 without re-walking the source paths.
BUNDLED_BASENAMES=()
for src in "${DYLIB_SOURCES[@]}"; do
    BUNDLED_BASENAMES+=("$(basename "$src")")
done

for dylib in "$APP_FRAMEWORKS"/*.dylib; do
    base="$(basename "$dylib")"
    install_name_tool -id "@rpath/$base" "$dylib"

    # Walk this dylib's LC_LOAD_DYLIB entries. `otool -L` gives one
    # path per line after the header line.
    otool -L "$dylib" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        # Bail on system / SDK paths — those stay as-is.
        case "$dep" in
            /usr/lib/*|/System/*) continue ;;
        esac
        dep_base="$(basename "$dep")"
        # Only rewrite when the dep is a dylib we're bundling.
        for bundled in "${BUNDLED_BASENAMES[@]}"; do
            if [[ "$dep_base" == "$bundled" ]]; then
                install_name_tool -change "$dep" "@rpath/$bundled" "$dylib"
                break
            fi
        done
    done
done
log "Rewrote install names to @rpath/"

# Rewrite the main binary's LC_LOAD_DYLIB entries for tesseract +
# leptonica (the two weak-linked direct deps) to @rpath/ as well.
# Then add an LC_RPATH of @executable_path/../Frameworks so dyld
# can resolve the @rpath references against the bundled copies.
BINARY="$APP_MACOS/$APP_NAME"
for src in "${DYLIB_SOURCES[@]}"; do
    base="$(basename "$src")"
    if otool -L "$BINARY" | grep -q "$src"; then
        install_name_tool -change "$src" "@rpath/$base" "$BINARY"
    fi
done
# add_rpath fails if the rpath is already present; suppress the error
# so re-builds of an existing bundle don't break.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BINARY" 2>/dev/null || true
log "Rewrote main binary deps to @rpath; added LC_RPATH"

# Bundle humanist-cli alongside the main binary. It ships in
# Contents/MacOS/ so power users can invoke `Humanist.app/Contents/MacOS/humanist-cli`
# directly, and Scripts/install-cli.sh installs from the same swift
# build cache (.build/arm64-apple-macosx/release/) for $PATH.
# Same @rpath rewriting as the main binary so the bundled copy is
# self-contained against the .app's Frameworks/.
CLI_SRC="$REPO_ROOT/.build/arm64-apple-macosx/release/humanist-cli"
if [[ -x "$CLI_SRC" ]]; then
    cp "$CLI_SRC" "$APP_MACOS/humanist-cli"
    chmod +w "$APP_MACOS/humanist-cli"
    for src in "${DYLIB_SOURCES[@]}"; do
        base="$(basename "$src")"
        if otool -L "$APP_MACOS/humanist-cli" | grep -q "$src"; then
            install_name_tool -change "$src" "@rpath/$base" "$APP_MACOS/humanist-cli"
        fi
    done
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_MACOS/humanist-cli" 2>/dev/null || true
    log "Bundled humanist-cli into MacOS/ with @rpath deps"
else
    warn "humanist-cli not found at $CLI_SRC — skipping CLI bundling"
fi

# Bundle Tesseract traineddata (Phase C). Default is the four
# languages this project targets: English + ancient Greek + Latin +
# Hebrew. The bundled-tessdata path is picked up automatically by
# `TesseractOCREngine.detect()` via `Bundle.main.resourceURL`.
log "Bundling Tesseract traineddata"
TESSDATA_SRC="/opt/homebrew/share/tessdata"
TESSDATA_DEST="$APP_RESOURCES/tessdata"
mkdir -p "$TESSDATA_DEST"
for lang in eng grc lat heb; do
    src_file="$TESSDATA_SRC/$lang.traineddata"
    if [[ -f "$src_file" ]]; then
        cp -L "$src_file" "$TESSDATA_DEST/$lang.traineddata"
    else
        warn "Missing traineddata: $src_file — language $lang unavailable in bundled tessdata (run \`brew install tesseract-lang\`)"
    fi
done
log "Bundled traineddata: $(ls "$TESSDATA_DEST" 2>/dev/null | tr '\n' ' ')"

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

# Sign every bundled dylib before signing the main binary. The
# --deep flag on the binary signing pass would do this transitively,
# but signing them explicitly first lets us pin per-dylib options
# (no entitlements; dylibs aren't entry points) and produces clearer
# error output when a dylib fails to sign. Order matters when one
# bundled dylib loads another — the dependency must be signed first
# — but for notarization-valid signatures we just need them all
# signed by the same identity, which happens in any traversal order.
DYLIB_SIGN_OPTS=(--force --options runtime --sign "$CODESIGN_IDENTITY_RESOLVED")
if [[ "$CODESIGN_IDENTITY_RESOLVED" == "-" ]]; then
    DYLIB_SIGN_OPTS=(--force --options runtime --sign -)
else
    DYLIB_SIGN_OPTS+=(--timestamp)
fi
for dylib in "$APP_FRAMEWORKS"/*.dylib; do
    codesign "${DYLIB_SIGN_OPTS[@]}" "$dylib"
done
log "Signed $(ls "$APP_FRAMEWORKS"/*.dylib 2>/dev/null | wc -l | tr -d ' ') bundled dylibs"

if [[ -x "$APP_MACOS/humanist-cli" ]]; then
    codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$APP_MACOS/humanist-cli"
fi
codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$APP_MACOS/$APP_NAME"
codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

log "Verifying"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/    /'

log "Bundle:"
du -sh "$APP_BUNDLE"
log "Done."
