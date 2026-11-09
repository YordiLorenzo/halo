#!/bin/bash
# Assemble Halo.app from the SPM binary. No Xcode project needed, the only bundle
# requirement for a menu bar app is LSUIElement in Info.plist.
set -euo pipefail
cd "$(dirname "$0")"
CONF="${1:-release}"
swift build -c "$CONF"
APP="build/Halo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONF/Halo" "$APP/Contents/MacOS/Halo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sign with a Developer ID if one is available. This matters beyond distribution: TCC pins a
# code-signing requirement when you grant a permission, and an ad-hoc signature changes hash on
# every build, so Accessibility and Full Disk Access grants silently stop matching. A stable
# identity makes a grant survive rebuilds.
ID=$(security find-identity -v -p codesigning 2>/dev/null \
     | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [ -n "$ID" ]; then
  codesign --force --options runtime --timestamp \
           --entitlements Resources/Halo.entitlements \
           --sign "$ID" "$APP"
  echo "signed: $ID"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null
  echo "signed: ad-hoc (permission grants will not survive rebuilds)"
fi
echo "built $APP"
