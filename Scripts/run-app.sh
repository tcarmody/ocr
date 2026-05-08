#!/usr/bin/env bash
# Build + open the app. Kills any running Humanist process first;
# without this, `open` reuses the live instance and the freshly-
# rebuilt bundle never loads — we'd be silently testing a stale
# binary across multiple "rebuilds." (Caught when an in-app error
# message kept reading the old verbatim despite the new code being
# present in the bundle.)
source "$(dirname "$0")/_lib.sh"
"$SCRIPT_DIR/build-app.sh"
log "Killing any running $APP_NAME process"
pkill -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
# Brief wait so macOS releases the bundle's lock before we re-open.
sleep 0.5
log "Launching $APP_BUNDLE"
open "$APP_BUNDLE"
