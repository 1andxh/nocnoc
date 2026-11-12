#!/bin/sh
# Package a release: build/release/nocnoc-<version>.zip and its SHA-256.
#
#   scripts/release.sh
#
# Local only. It never tags, pushes or uploads; it prints those commands for
# you to run. It refuses unless:
#   - the working tree is clean, so the zip is exactly what's committed, and
#   - HEAD is tagged v<version> (version = Router.version), so anyone can
#     check out the tag later and rebuild what users actually downloaded.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/^ *public static let version = "\([^"]*\)".*/\1/p' Sources/NocnocCore/Router.swift)"
TAG="v$VERSION"

if [ -n "$(git status --porcelain)" ]; then
  echo "release.sh: working tree has uncommitted changes; commit or stash them first." >&2
  exit 1
fi
if ! git tag --points-at HEAD | grep -qx "$TAG"; then
  echo "release.sh: HEAD isn't tagged $TAG (Router.version is $VERSION)." >&2
  echo "  bump Router.version if needed, commit, then:  git tag $TAG" >&2
  exit 1
fi

swift test
APP="$(scripts/build-app.sh)"

# Belt and braces: the bundle must say the version we're about to publish.
BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$BUILT" = "$VERSION" ] || { echo "release.sh: bundle says $BUILT, expected $VERSION" >&2; exit 1; }

OUT="$ROOT/build/release"
ZIP="$OUT/nocnoc-$VERSION.zip"
mkdir -p "$OUT"
rm -f "$ZIP"
# ditto, not zip: keeps the bundle's symlinks, permissions and signature intact.
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

cat <<EOF

Built $ZIP
sha256 $SHA

Next (you run these):
  git push origin $TAG
  gh release create $TAG "$ZIP" --title "nocnoc $VERSION" --generate-notes

Then in the tap's Casks/nocnoc.rb:
  version "$VERSION"
  sha256 "$SHA"

Note: this build is ad-hoc signed. Downloaded copies are quarantined and
Gatekeeper will refuse to open them until the app is Developer ID signed and
notarized.
EOF
