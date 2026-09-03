#!/bin/bash
# Builds SmartDock.app and packages it into an installable DMG.
# Usage: scripts/build-release.sh [version]   (default 1.0.0)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=SmartDock
VERSION="${1:-1.0.0}"
BUNDLE_ID="com.smartdock.SmartDock"
DIST=dist
APP_BUNDLE="$DIST/$APP.app"
DMG="$DIST/$APP-$VERSION.dmg"

echo "── building release binary"
swift build -c release

echo "── assembling $APP_BUNDLE"
rm -rf "$DIST"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp ".build/release/$APP" "$APP_BUNDLE/Contents/MacOS/$APP"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$APP</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>$APP</string>
	<key>CFBundleDisplayName</key><string>$APP</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

IDENTITY="${CODESIGN_ID:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "SmartDock Code Signing"; then
    IDENTITY="SmartDock Code Signing"
fi
if [ -n "$IDENTITY" ]; then
    echo "── signing with '$IDENTITY' (permissions persist across rebuilds)"
else
    echo "── signing ad-hoc (run scripts/setup-signing.sh once to keep permissions across rebuilds)"
fi
codesign --force --sign "${IDENTITY:--}" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "── creating DMG"
DMG_ROOT="$DIST/dmg-root"
mkdir -p "$DMG_ROOT"
cp -R "$APP_BUNDLE" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "$APP" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_ROOT"

echo
echo "done: $DMG"
if [ -n "$IDENTITY" ]; then
    echo "signed with a stable identity — existing permission grants carry over."
else
    echo "note: ad-hoc signatures change every build, so Accessibility must be"
    echo "      re-granted after each reinstall. Run scripts/setup-signing.sh once"
    echo "      to fix that permanently."
fi
