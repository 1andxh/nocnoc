#!/bin/sh
# Build build/nocnoc.app from the Swift package.
#
# Why a .app and not just the binary: macOS only grants notification
# permission to a bundle with an identifier (Info.plist). A bare executable
# from `swift build` can't post notifications.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product nocnoc
swift build -c release --product nocnoc-mcp
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/nocnoc.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/nocnoc" "$APP/Contents/MacOS/nocnoc"
# The MCP server agents launch (Phase 5). Lives in the bundle so there's one
# thing to build and one path to register.
cp "$BIN_DIR/nocnoc-mcp" "$APP/Contents/MacOS/nocnoc-mcp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# The hook script ships inside the app too, so agent configs can point at
# the installed app rather than at this repo (which may move).
mkdir -p "$APP/Contents/Resources"
# App icon (regenerate with: swift scripts/make-icon.swift)
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/hooks/nocnoc-hook.sh" "$APP/Contents/Resources/nocnoc-hook.sh"
chmod +x "$APP/Contents/Resources/nocnoc-hook.sh"

# Ad-hoc signature: enough for a locally built app to run and ask for
# notification permission. (Sharing it with others would need a real
# Developer ID + notarization.)
codesign --force --sign - "$APP/Contents/MacOS/nocnoc-mcp"
codesign --force --sign - "$APP"

echo "$APP"
