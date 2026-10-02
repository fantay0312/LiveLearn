#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/Vendor/ChatterflyBridge"
DEST="$ROOT/build/components/chatterfly"
mkdir -p "$DEST"
echo "▸ building Chatterfly protocol bridge"
if ! swift build --package-path "$PACKAGE" -c release > "$DEST/build.log" 2>&1; then
  tail -30 "$DEST/build.log"
  exit 1
fi
BIN="$(swift build --package-path "$PACKAGE" -c release --show-bin-path)"
cp "$BIN/LiveLearnChatterfly" "$DEST/LiveLearnChatterfly"
setopt +o nomatch
for resource in "$BIN"/*.bundle(N); do
  rm -rf "$DEST/$(basename "$resource")"
  cp -R "$resource" "$DEST/"
done
OPUS_LINK="$(otool -L "$DEST/LiveLearnChatterfly" | awk '/libopus.*dylib/ {print $1; exit}')"
[[ -n "$OPUS_LINK" ]] || exit 1
install_name_tool -change "$OPUS_LINK" '@executable_path/../Frameworks/libopus.0.dylib' "$DEST/LiveLearnChatterfly"
codesign --force --sign - "$DEST/LiveLearnChatterfly"
