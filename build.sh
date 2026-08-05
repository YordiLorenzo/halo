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
# Ad-hoc sign so TCC can identify the bundle consistently between launches;
# a real release needs a Developer ID identity and notarisation.
codesign --force --deep --sign - "$APP" 2>/dev/null
echo "built $APP"
