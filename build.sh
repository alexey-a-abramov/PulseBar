#!/usr/bin/env bash
#
# Builds PulseBar.app (a self-contained, ad-hoc-signed .app bundle) plus a bare
# CLI binary, both under ./build. No Xcode project required — one clang call.
#
set -euo pipefail

APP_NAME="PulseBar"
BUNDLE_ID="com.fun.pulsebar"
VERSION="1.3.0"                 # marketing version (CFBundleShortVersionString)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRC="$ROOT/Sources"
BUILD="$ROOT/build"
APPDIR="$BUILD/$APP_NAME.app"
MACOS="$APPDIR/Contents/MacOS"
BUILD_NUM="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"   # auto-increments with each commit

echo "==> Building $APP_NAME"
rm -rf "$BUILD"
mkdir -p "$MACOS" "$APPDIR/Contents/Resources"

cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUM</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Open source. Uses private Touch Bar SPI.</string>
  <key>NSMicrophoneUsageDescription</key><string>PulseBar listens to your voice commands for the agent.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>PulseBar transcribes your voice commands (on-device) for the agent.</string>
</dict>
</plist>
PLIST

SDK="$(xcrun --sdk macosx --show-sdk-path)"
echo "==> SDK: $SDK"

clang -fobjc-arc -O2 -mmacosx-version-min=12.0 -isysroot "$SDK" \
  -Wall -Wno-deprecated-declarations \
  "$SRC/PBDefaults.m" "$SRC/PBProcess.m" "$SRC/PBFormat.m" "$SRC/PBLayout.m" "$SRC/Log.m" "$SRC/Stats.m" "$SRC/Controls.m" "$SRC/Pomodoro.m" \
  "$SRC/AppIndex.m" "$SRC/VoiceCommands.m" "$SRC/Queries.m" \
  "$SRC/BarView.m" "$SRC/PreviewData.m" "$SRC/TouchBarPresenter.m" "$SRC/MirrorController.m" \
  "$SRC/Agent.m" "$SRC/AgentWindowController.m" "$SRC/AgentCoordinator.m" "$SRC/VoiceNotes.m" \
  "$SRC/SettingsWindowController.m" "$SRC/LayoutEditorWindowController.m" \
  "$SRC/CrashReporter.m" "$SRC/ModifierMonitor.m" "$SRC/PBLoginItem.m" "$SRC/PBBreakReminder.m" "$SRC/AppDelegate.m" "$SRC/main.m" \
  -framework AppKit -framework Foundation -framework CoreFoundation \
  -framework IOKit -framework QuartzCore -framework CoreGraphics -framework CoreAudio \
  -framework Speech -framework AVFoundation -framework ApplicationServices \
  -o "$MACOS/$APP_NAME"

# Ad-hoc code signature (private API needs no entitlements; this just keeps
# Gatekeeper/launchd happy for a locally-built bundle).
# Prefer a STABLE local identity ("PulseBar Local Signing", a self-signed
# codesigning cert) so macOS TCC keeps Accessibility/Mic/Speech grants across
# rebuilds. Falls back to ad-hoc (which re-prompts every build) if it's absent.
SIGN_ID="PulseBar Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" "$APPDIR" >/dev/null 2>&1 && echo "==> signed ($SIGN_ID — stable identity)" || echo "==> (codesign failed)"
else
  codesign --force --sign - "$APPDIR" >/dev/null 2>&1 && echo "==> ad-hoc signed (grants will re-prompt each build; see README to create a stable identity)" || echo "==> (codesign skipped)"
fi

cp "$MACOS/$APP_NAME" "$BUILD/$APP_NAME"   # bare binary for quick CLI launch

echo "==> Built: $APPDIR"
echo "    bare binary: $BUILD/$APP_NAME"

# `build.sh --install` copies the bundle to /Applications (falls back to
# ~/Applications if that's not writable) so Spotlight/Raycast can launch it.
if [ "${1:-}" = "--install" ]; then
  DEST="/Applications"
  if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
  rm -rf "$DEST/$APP_NAME.app"
  ditto "$APPDIR" "$DEST/$APP_NAME.app"
  # Drop any quarantine attr just in case, so first launch isn't blocked.
  xattr -dr com.apple.quarantine "$DEST/$APP_NAME.app" 2>/dev/null || true
  echo "==> Installed: $DEST/$APP_NAME.app"
fi
