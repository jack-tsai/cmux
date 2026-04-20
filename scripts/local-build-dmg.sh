#!/usr/bin/env bash
set -euo pipefail

# Local unsigned (ad-hoc) DMG build for fork users without Apple Developer credentials.
# Produces cmux-macos.dmg in project root.
#
# Why ad-hoc re-sign: xcodebuild with CODE_SIGNING_ALLOWED=NO produces a
# linker-signed bundle with Sealed Resources=none. macOS TCC cannot pin user
# consent to a linker-signed identity, so every file-access permission prompt
# re-appears on every launch. A real ad-hoc codesign (Identifier + Sealed
# Resources) gives TCC a stable anchor, so "Allow" sticks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

APP_PATH="build/Build/Products/Release/cmux.app"
DMG_PATH="cmux-macos.dmg"
# cmux.entitlements includes `com.apple.developer.web-browser.public-key-credential`
# and other `com.apple.developer.*` keys that REQUIRE a real Apple Developer ID
# signature — ad-hoc signing with them causes AMFI to kill the launch.
# cmux.local.entitlements strips those while keeping the hardened-runtime keys
# (disable-library-validation etc.) needed so Sparkle/Sentry frameworks load.
ENTITLEMENTS="cmux.local.entitlements"

for tool in xcodebuild codesign create-dmg; do
  command -v "$tool" >/dev/null || { echo "MISSING: $tool" >&2; exit 1; }
done

echo "==> Building Release (unsigned)..."
# CMUX_SKIP_ZIG_BUILD=1: skip building the bundled `ghostty` CLI helper via zig.
# ghostty requires zig 0.15.2 specifically, but Homebrew currently ships 0.16.
# A stub helper is installed instead. Terminal core (libghostty.a) comes from the
# prebuilt xcframework, so typing/rendering are unaffected — only the in-app
# `ghostty` CLI command would fail if invoked.
#
# Preserve xcodebuild's exit code across the pipe (tail would otherwise mask it).
set -o pipefail
CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
  -scheme cmux \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -10

[[ -d "$APP_PATH" ]] || { echo "error: $APP_PATH not found after build" >&2; exit 1; }

echo "==> Ad-hoc re-signing (required for stable TCC identity)..."
codesign \
  --deep --force --sign - \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  "$APP_PATH"

echo "==> Verifying signature..."
codesign -dvv "$APP_PATH" 2>&1 | grep -E 'Identifier|Signature|Sealed Resources'

echo "==> Creating DMG with Applications shortcut..."
# Build the DMG via hdiutil directly to avoid create-dmg's AppleScript/Finder
# layout step (which hangs on permission prompts and produces runaway file
# sizes when Finder can't manipulate the mounted disk).
STAGE_DIR="$(mktemp -d /tmp/cmux-dmg-stage.XXXXXXXX)"
trap 'rm -rf "$STAGE_DIR" /tmp/cmux-temp-dmg.$$.dmg' EXIT
ditto "$APP_PATH" "$STAGE_DIR/cmux.app"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH" "/tmp/cmux-temp-dmg.$$.dmg"
hdiutil create \
  -fs HFS+ \
  -srcfolder "$STAGE_DIR" \
  -volname "cmux" \
  -format UDZO \
  -ov \
  "/tmp/cmux-temp-dmg.$$.dmg" >/dev/null
mv "/tmp/cmux-temp-dmg.$$.dmg" "$DMG_PATH"

echo ""
echo "==> Done"
echo "    App:  $PROJECT_DIR/$APP_PATH"
echo "    DMG:  $PROJECT_DIR/$DMG_PATH  ($(du -h "$DMG_PATH" | cut -f1))"
echo ""
echo "Install: open $DMG_PATH → drag cmux.app to Applications."
echo "First launch: right-click → Open (Gatekeeper bypass). Allow TCC prompts once; consent will persist."
