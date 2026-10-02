#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/Vendor/DictationEngine"
DEST="$ROOT/build/components/dictation"
mkdir -p "$DEST"
command -v pkg-config >/dev/null
OPUS_LIB="$(pkg-config --variable=libdir opus)"
OPUS_PREFIX="$(pkg-config --variable=prefix opus)"
echo "▸ building the isolated dictation engine"
if ! swift build --package-path "$ENGINE" -c release > "$DEST/build.log" 2>&1; then
  tail -40 "$DEST/build.log"
  exit 1
fi
BIN="$(swift build --package-path "$ENGINE" -c release --show-bin-path)/typeless-engine"
cp "$BIN" "$DEST/LiveLearnDictation"
cp -fL "$OPUS_LIB/libopus.0.dylib" "$DEST/libopus.0.dylib"
chmod u+w "$DEST/libopus.0.dylib"
cp "$OPUS_PREFIX/COPYING" "$DEST/Opus-LICENSE.txt"
OPUS_LINK="$(otool -L "$DEST/LiveLearnDictation" | awk '/libopus.*dylib/ {print $1; exit}')"
[[ -n "$OPUS_LINK" ]] || { echo "missing Opus dependency"; exit 1; }
install_name_tool -change "$OPUS_LINK" '@executable_path/../Frameworks/libopus.0.dylib' "$DEST/LiveLearnDictation"
install_name_tool -id '@rpath/libopus.0.dylib' "$DEST/libopus.0.dylib"
codesign --force --sign - "$DEST/libopus.0.dylib"
codesign --force --sign - "$DEST/LiveLearnDictation"
