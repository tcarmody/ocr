#!/usr/bin/env bash
# Build `humanist-cli` in release mode and install it onto $PATH so
# `library-dedupe`, `convert`, `compare`, etc. can be invoked from
# anywhere without remembering the .build/release/ path.
#
# Default install dir is ~/.local/bin (already on $PATH in this
# user's shell config). Override with HUMANIST_CLI_INSTALL_DIR
# or as the first argument:
#
#     ./Scripts/install-cli.sh                      # ~/.local/bin
#     ./Scripts/install-cli.sh ~/bin                # explicit
#     HUMANIST_CLI_INSTALL_DIR=/usr/local/bin ...   # via env
#
# This script is independent of `Scripts/run-app.sh` — that one
# only builds + launches the SwiftUI bundle. CLI users have to
# re-run this after any pull that touches HumanistCLI/.
source "$(dirname "$0")/_lib.sh"

INSTALL_DIR="${1:-${HUMANIST_CLI_INSTALL_DIR:-$HOME/.local/bin}}"
mkdir -p "$INSTALL_DIR"

log "Building humanist-cli (release, arm64)"
# Match Scripts/build-app.sh's arch so we hit the same SwiftPM build
# cache — running build-app.sh then install-cli.sh (or vice-versa) does
# one compile, not two. The output dir is .build/arm64-apple-macosx/release/
# rather than the default .build/release/.
swift build --product humanist-cli -c release --arch arm64

BIN_PATH="$(swift build --product humanist-cli --show-bin-path -c release --arch arm64)/humanist-cli"
if [[ ! -x "$BIN_PATH" ]]; then
    die "Expected build artifact missing at $BIN_PATH"
fi

DEST="$INSTALL_DIR/humanist-cli"
cp "$BIN_PATH" "$DEST"
chmod +x "$DEST"
log "Installed $DEST"

# Sanity check: a `command -v` resolves through $PATH the same way
# the user's shell does, so a successful match means the install
# dir really is on $PATH for this session's environment.
if RESOLVED="$(command -v humanist-cli 2>/dev/null)"; then
    if [[ "$RESOLVED" == "$DEST" ]]; then
        VERSION="$("$DEST" --version 2>/dev/null || echo unknown)"
        log "humanist-cli on \$PATH resolves to $RESOLVED (version $VERSION)"
    else
        warn "humanist-cli on \$PATH resolves to $RESOLVED — a different copy is shadowing $DEST."
        warn "Either remove the other copy or reorder \$PATH so $INSTALL_DIR wins."
    fi
else
    warn "$INSTALL_DIR is not on your \$PATH."
    warn "Add this to your shell rc (e.g. ~/.zshrc):"
    warn "    export PATH=\"$INSTALL_DIR:\$PATH\""
fi
