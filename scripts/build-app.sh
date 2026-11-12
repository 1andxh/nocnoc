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
# The version people see (and Homebrew compares) comes from the one constant
# in Router.swift, so the app and its /v1/health can never disagree.
VERSION="$(sed -n 's/^ *public static let version = "\([^"]*\)".*/\1/p' "$ROOT/Sources/NocnocCore/Router.swift")"
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "build-app.sh: can't read Router.version (got '$VERSION')" >&2; exit 1 ;;
esac
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
# A build number that grows with every commit. macOS caches app icons (and
# other per-app data) by bundle id + build number; a constant "1" made it
# keep serving the first, icon-less build forever.
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
# The hook script ships inside the app too, so agent configs can point at
# the installed app rather than at this repo (which may move).
mkdir -p "$APP/Contents/Resources"
# App icon (regenerate with: swift scripts/make-icon.swift). Compiled into an
# asset catalog (Assets.car, found via CFBundleIconName) the way Xcode does,
# with the .icns kept as the fallback for older lookups.
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
xcrun actool "$ROOT/Resources/Assets.xcassets" --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$(mktemp -d)/partial.plist" > /dev/null
cp "$ROOT/hooks/nocnoc-hook.sh" "$APP/Contents/Resources/nocnoc-hook.sh"
chmod +x "$APP/Contents/Resources/nocnoc-hook.sh"

# Ad-hoc signature: enough for a locally built app to run and ask for
# notification permission. (Sharing it with others would need a real
# Developer ID + notarization.)
codesign --force --sign - "$APP/Contents/MacOS/nocnoc-mcp"
codesign --force --sign - "$APP"

echo "$APP"
