#!/usr/bin/env bash
#
# Build a distributable drag-to-Applications DMG for F Wrds.
#
# Usage:   ./scripts/make-dmg.sh
# Output:  dist/FWrds-<version>.dmg   (version from App/project.yml MARKETING_VERSION)
# Needs:   xcodegen, create-dmg   (brew install xcodegen create-dmg)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/App"
BUILD_DIR="$APP_DIR/build/release"
DIST_DIR="$ROOT/dist"

command -v xcodegen   >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)"   >&2; exit 1; }
command -v create-dmg >/dev/null || { echo "error: create-dmg not found (brew install create-dmg)" >&2; exit 1; }

# Tolerates every spelling YAML allows for the same value — MARKETING_VERSION: "0.1.0", '0.1.0' or
# a bare 0.1.0 — rather than only the quoted one. The old pattern reached for whatever was between
# the first pair of quotes on the line and, with none there, handed back the whole line: an
# unquoted version would have produced a DMG named after a build setting.
VERSION="$(
  grep -m1 -E '^[[:space:]]*MARKETING_VERSION:' "$APP_DIR/project.yml" \
    | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*(#.*)?$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
)"
[ -n "$VERSION" ] || { echo "error: no MARKETING_VERSION in $APP_DIR/project.yml" >&2; exit 1; }
echo "==> Building F Wrds $VERSION (Release)"

cd "$APP_DIR"
xcodegen
xcodebuild -project FWrds.xcodeproj -scheme FWrds \
  -configuration Release -derivedDataPath build/release \
  -destination 'platform=macOS' clean build

APP="$BUILD_DIR/Build/Products/Release/F Wrds.app"
[ -d "$APP" ] || { echo "error: build did not produce $APP" >&2; exit 1; }
"$ROOT/scripts/sign-app.sh" "$APP"

mkdir -p "$DIST_DIR"
STAGE="$(mktemp -d)"
VOLUME="/Volumes/F Wrds"
# create-dmg mounts the image it is building to lay the window out, and a run interrupted partway
# — ⌃C, a failed build step — leaves that volume mounted. The next run then finds the name taken
# and mounts as "F Wrds 1", which silently produces a DMG whose window settings were applied to a
# volume the user never sees. Detaching here means an interrupted run costs nothing but a retry.
trap 'rm -rf "$STAGE"; [ -d "$VOLUME" ] && hdiutil detach "$VOLUME" -force >/dev/null 2>&1; true' EXIT
cp -R "$APP" "$STAGE/"

DMG="$DIST_DIR/FWrds-$VERSION.dmg"
rm -f "$DMG"

echo "==> Packaging $DMG"
create-dmg \
  --volname "F Wrds" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "F Wrds.app" 150 190 \
  --hide-extension "F Wrds.app" \
  --app-drop-link 450 190 \
  --no-internet-enable \
  "$DMG" "$STAGE"

echo "==> Done"
ls -lh "$DMG"
shasum -a 256 "$DMG"
