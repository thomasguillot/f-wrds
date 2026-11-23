#!/usr/bin/env bash
#
# Sign an F Wrds build with a stable code-signing identity, when one is available.
#
# Usage:   ./scripts/sign-app.sh "path/to/F Wrds.app"
# Env:     FWRDS_SIGN_IDENTITY  identity name or SHA-1 (default "F Wrds Local Signing")
#
# macOS records the Accessibility and Input Monitoring grants against an app's designated
# requirement. An ad-hoc signature's requirement is its code hash, which changes with every
# build, so each new build loses both grants. Signing with the same certificate every time
# gives a requirement of "this bundle ID, this certificate", which survives rebuilds and
# updates. A self-signed certificate is enough for that; it changes nothing about Gatekeeper.
# Without the identity the build is left ad-hoc signed, as Xcode produced it.
#
set -euo pipefail

APP="${1:?usage: sign-app.sh <path to F Wrds.app>}"
IDENTITY="${FWRDS_SIGN_IDENTITY:-F Wrds Local Signing}"

if security find-identity -p codesigning | grep -qF "\"$IDENTITY\""; then
  codesign --force --deep --sign "$IDENTITY" --identifier com.fwrds.app "$APP"
  echo "==> Signed with \"$IDENTITY\""
else
  echo "warning: no \"$IDENTITY\" code-signing identity; leaving the build ad-hoc signed," \
       "so macOS will ask for both permissions again after this install" >&2
fi
