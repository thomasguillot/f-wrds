#!/usr/bin/env bash
#
# Build F Wrds (Release), sign it, install it to /Applications and relaunch it.
#
# Usage:   ./scripts/install-local.sh
# Needs:   xcodegen. Optionally a code-signing identity named by FWRDS_SIGN_IDENTITY
#          (default "F Wrds Local Signing"); see scripts/sign-app.sh for why it matters.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/App/build/release/Build/Products/Release/F Wrds.app"
DEST="/Applications/F Wrds.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }

cd "$ROOT/App"
xcodegen -q
xcodebuild -project FWrds.xcodeproj -scheme FWrds -configuration Release \
  -derivedDataPath build/release -destination 'platform=macOS' -quiet build

"$ROOT/scripts/sign-app.sh" "$APP"

osascript -e 'quit app "F Wrds"' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do pgrep -x "F Wrds" >/dev/null || break; sleep 1; done
pkill -x "F Wrds" 2>/dev/null || true

rm -rf "$DEST"
ditto "$APP" "$DEST"
# The build folder's copy would otherwise compete with the installed one in Spotlight and Launchpad.
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

# The Dock caches icons per bundle version, so a new icon under the same version shows the old one
# until the bundle is touched and the Dock restarted.
touch "$DEST"
killall Dock 2>/dev/null || true

open "$DEST"
echo "==> Installed and relaunched $DEST"
