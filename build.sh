#!/bin/bash
#
# Build PixelDancer Power Helper.
#
# Steps:
#   1. swift build -c release        — compile both executables
#   2. Assemble the .app bundle structure
#   3. (Optional) codesign + create DMG  — manual, see README
#
# Output: build/PixelDancerPowerHelper.app — drag to /Applications and run.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="PixelDancer Power Helper"
APP_DIR="build/${APP_NAME}.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
LAUNCHD_DIR="$APP_DIR/Contents/Library/LaunchDaemons"

echo "▶ Building Swift Package (release)…"
swift build -c release --product PixelDancerPowerHelper
swift build -c release --product PixelDancerPowerHelperDaemon

# Where SPM puts the binaries.
BUILD_PATH="$(swift build -c release --show-bin-path)"

echo "▶ Assembling bundle: $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$LAUNCHD_DIR"

# Binaries
cp "$BUILD_PATH/PixelDancerPowerHelper"        "$BIN_DIR/PixelDancerPowerHelper"
cp "$BUILD_PATH/PixelDancerPowerHelperDaemon"  "$BIN_DIR/PixelDancerPowerHelperDaemon"
chmod +x "$BIN_DIR/PixelDancerPowerHelper" "$BIN_DIR/PixelDancerPowerHelperDaemon"

# Bundle metadata
cp Bundle/Info.plist "$APP_DIR/Contents/Info.plist"
cp Bundle/LaunchDaemons/com.vm.PixelDancerPowerHelper.daemon.plist "$LAUNCHD_DIR/"

# App icon (Resources/AppIcon.icns referenced by CFBundleIconFile in Info.plist)
mkdir -p "$APP_DIR/Contents/Resources"
cp Bundle/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

# PkgInfo (some macOS subsystems sniff for this)
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Permissions: daemon plist must be 0644 root:wheel after install; for build
# output we leave it user-owned (the user copying to /Applications inherits
# correct perms via Finder, or pkgbuild handles it during signed install).
chmod 0644 "$LAUNCHD_DIR/com.vm.PixelDancerPowerHelper.daemon.plist"

echo "▶ Verifying bundle"
ls -la "$APP_DIR/Contents/" >&2
ls -la "$BIN_DIR/" >&2
ls -la "$LAUNCHD_DIR/" >&2

echo ""
echo "✅ Built: $APP_DIR"
echo ""
echo "Next steps (manual, see README.md):"
echo "  1. Codesign with Developer ID Application:"
echo "       codesign --deep --options runtime --sign 'Developer ID Application: <NAME> (TEAM_ID)' \\"
echo "         --entitlements Entitlements/daemon.entitlements \\"
echo "         '$BIN_DIR/PixelDancerPowerHelperDaemon'"
echo "       codesign --options runtime --sign 'Developer ID Application: <NAME> (TEAM_ID)' \\"
echo "         --entitlements Entitlements/app.entitlements \\"
echo "         '$APP_DIR'"
echo "  2. Notarize:"
echo "       xcrun notarytool submit '$APP_DIR.zip' --apple-id <APPLE_ID> \\"
echo "         --team-id <TEAM_ID> --password <APP_SPECIFIC_PASSWORD> --wait"
echo "  3. Staple:"
echo "       xcrun stapler staple '$APP_DIR'"
echo "  4. Create DMG:"
echo "       hdiutil create -volname 'PixelDancer Power Helper' -srcfolder build \\"
echo "         -ov -format UDZO build/PixelDancerPowerHelper-1.0.0.dmg"
