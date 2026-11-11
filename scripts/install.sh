#!/bin/sh
# Build nocnoc and install it to ~/Applications/nocnoc.app, then (re)start it.
#
# Agent configs point at the installed copy, not this repo:
#   hook: ~/Applications/nocnoc.app/Contents/Resources/nocnoc-hook.sh
#   mcp:  ~/Applications/nocnoc.app/Contents/MacOS/nocnoc-mcp
# so the repo can move without breaking them. Re-run after every change.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications/nocnoc.app"

"$ROOT/scripts/build-app.sh" > /dev/null

# Stop the running copy (wherever it runs from) so the new one can own the socket.
osascript -e 'quit app id "local.nocnoc.app"' 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x nocnoc > /dev/null || break; sleep 0.5; done

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$ROOT/build/nocnoc.app" "$DEST"
open "$DEST"

echo "installed $DEST"
