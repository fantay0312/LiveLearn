#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/build/brand-tools"
ICONSET="$ROOT/build/brand/LiveLearn.iconset"
ASSETS="$ROOT/Assets/Brand"
SOURCE_HASH="$(cat "$ROOT/Sources/LiveLearnApp/DesignSystem/BrandGeometry.swift" "$ROOT/script/generate_brand_assets.swift" "$ROOT/script/generate_brand_assets.sh" | shasum -a 256 | awk '{print $1}')"
if [[ -f "$ASSETS/.asset-inputs.sha256" && "$(cat "$ASSETS/.asset-inputs.sha256")" == "$SOURCE_HASH" \
      && -f "$ASSETS/AppIcon.icns" && -f "$ASSETS/MenuBarTemplate.pdf" && -f "$ASSETS/MenuBarActiveTemplate.pdf" ]]; then
  echo "▸ brand assets are current"
  exit 0
fi
mkdir -p "$TOOLS" "$ASSETS"
swiftc "$ROOT/Sources/LiveLearnApp/DesignSystem/BrandGeometry.swift" \
  "$ROOT/script/generate_brand_assets.swift" -o "$TOOLS/generate-brand-assets"
"$TOOLS/generate-brand-assets" "$ASSETS" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ASSETS/AppIcon.icns"
print -r -- "$SOURCE_HASH" > "$ASSETS/.asset-inputs.sha256"
