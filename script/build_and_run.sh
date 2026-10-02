#!/bin/zsh
# Builds LiveLearn with SwiftPM, assembles a real .app bundle, signs it ad-hoc, stops any old
# instance and launches the new one. `swift run` on a bare executable is NOT a substitute:
# TCC prompts (microphone, system audio) and NSPanel behaviour only apply to a signed .app.
#
# Usage:
#   script/build_and_run.sh              # debug build, launch
#   script/build_and_run.sh --release    # release build, launch
#   script/build_and_run.sh --previews   # render design previews to doc/previews and exit
#   script/build_and_run.sh --no-launch  # build + bundle only
#   script/build_and_run.sh --logs       # stream this app's logs (after launch)
# Default builds contain the realtime translation core only.
#
# Dev-loop note: the bundle is ad-hoc signed. macOS ties TCC grants to the code signature, so
# after some rebuilds the system may ask for microphone / system audio permission again. That
# is expected for ad-hoc builds; Developer ID signing removes it and is required for release.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG=debug
LAUNCH=1
PREVIEWS=0
LOGS=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG=release ;;
    --no-launch) LAUNCH=0 ;;
    --previews) PREVIEWS=1; LAUNCH=0 ;;
    --logs) LOGS=1 ;;
    *) echo "Unknown option: $arg"; exit 2 ;;
  esac
done

if [[ $LOGS -eq 1 ]]; then
  # zsh has a builtin named `log`; the unified-log tool must be called by path.
  exec /usr/bin/log stream --style compact --predicate 'process == "LiveLearn" OR subsystem == "com.fantasy.livelearn"'
fi

APP_NAME=LiveLearn
BUNDLE_ID=com.fantasy.livelearn
VERSION=0.1.0
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
# Assembled and signed here first; only a fully built bundle replaces the previous one, so a
# failed build never leaves a half-written or silently stale .app behind.
STAGING="$BUILD_DIR/$APP_NAME.staging.app"
BUILD_LOG="$BUILD_DIR/swift-build.log"
mkdir -p "$BUILD_DIR"

echo "▸ generating LiveLearn brand assets"
zsh "$ROOT/script/generate_brand_assets.sh"

echo "▸ swift build -c $CONFIG"
# The compiler's real exit code decides; nothing downstream runs on a failed build.
if ! swift build -c "$CONFIG" --product "$APP_NAME" >"$BUILD_LOG" 2>&1; then
  grep -E "error:" "$BUILD_LOG" | head -20
  echo "✗ build failed; full log: $BUILD_LOG"
  echo "  the previous bundle at $APP was left untouched"
  exit 1
fi
grep -E "warning: unre|complete!" "$BUILD_LOG" | tail -3 || true
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN"; exit 1; }

echo "▸ assembling $APP"
rm -rf "$STAGING"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources" "$STAGING/Contents/Helpers" "$STAGING/Contents/PlugIns"
mkdir -p "$STAGING/Contents/Frameworks"
cp "$BIN" "$STAGING/Contents/MacOS/$APP_NAME"
cp "$ROOT/Assets/Brand/AppIcon.icns" "$STAGING/Contents/Resources/"
cp "$ROOT/Vendor/ThinkingOrbsKit/LICENSE" "$STAGING/Contents/Resources/ThinkingOrbsKit-LICENSE.txt"
mkdir -p "$STAGING/Contents/Resources/Licenses"
cp "$ROOT/LICENSE" "$STAGING/Contents/Resources/Licenses/LiveLearn-GPL-3.0.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGING/Contents/Resources/Licenses/"
for dependency in argmax-oss-swift ZIPFoundation swift-argument-parser; do
  for notice in "$ROOT/.build/checkouts/$dependency/"{LICENSE,LICENSE.txt,NOTICE.txt}(N); do
    cp "$notice" "$STAGING/Contents/Resources/Licenses/$dependency-$(basename "$notice")"
  done
done
cp "$ROOT/Assets/Brand/MenuBarTemplate.pdf" "$ROOT/Assets/Brand/MenuBarActiveTemplate.pdf" "$STAGING/Contents/Resources/"
# Copy any SwiftPM resource bundles next to the binary.
setopt +o nomatch
for bundle in "$(dirname "$BIN")"/*.bundle(N); do
  [[ -d "$bundle" ]] && cp -R "$bundle" "$STAGING/Contents/Resources/"
done

cat > "$STAGING/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>CFBundleURLTypes</key>
  <array><dict><key>CFBundleURLName</key><string>com.fantasy.livelearn.translation</string>
    <key>CFBundleURLSchemes</key><array><string>livelearn</string></array></dict></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSMicrophoneUsageDescription</key>
  <string>在你启用麦克风字幕或语音输入时，LiveLearn 读取所选麦克风。本地引擎在本机识别；选择云端引擎后，音频会发送到该服务。</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>LiveLearn 只采集你选定的应用或系统声音，用于生成实时字幕。是否上传音频和文本取决于你选择的识别与翻译引擎。</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>LiveLearn 使用系统自带的本机语音识别把声音变成文字；模型在本机运行，不上传音频。</string>
</dict>
</plist>
PLIST

cat > "$BUILD_DIR/$APP_NAME.entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENT

echo "▸ codesign (ad-hoc)"
if ! codesign --force --deep --sign - --identifier "$BUNDLE_ID" --entitlements "$BUILD_DIR/$APP_NAME.entitlements" "$STAGING" 2>&1 | grep -v "replacing existing signature"; then
  : # grep returns 1 when the only output was the "replacing" notice; codesign's own failure is caught by verify below
fi
if ! codesign --verify --strict --deep "$STAGING"; then
  echo "✗ signature verification failed; previous bundle left untouched"
  rm -rf "$STAGING"
  exit 1
fi
echo "  signature ok"
rm -rf "$APP"
mv "$STAGING" "$APP"
# The helper is a build component, never a second application to install or launch.
if [[ -d "$BUILD_DIR/LiveLearnTranslation.app" ]]; then
  mv "$BUILD_DIR/LiveLearnTranslation.app" "$BUILD_DIR/components/LiveLearnTranslation.previous.app"
fi

if [[ $PREVIEWS -eq 1 ]]; then
  OUT="$ROOT/doc/previews"
  echo "▸ rendering previews to $OUT"
  "$APP/Contents/MacOS/$APP_NAME" --render-previews "$OUT"
  ls -la "$OUT"
  exit 0
fi

if [[ $LAUNCH -eq 1 ]]; then
  echo "▸ stopping old instance"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.3
  echo "▸ launching $APP"
  open "$APP"
  echo "  logs: script/build_and_run.sh --logs"
fi
