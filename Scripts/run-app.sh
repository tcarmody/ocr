#!/usr/bin/env bash
# Build + open the app.
source "$(dirname "$0")/_lib.sh"
"$SCRIPT_DIR/build-app.sh"
log "Launching $APP_BUNDLE"
open "$APP_BUNDLE"
