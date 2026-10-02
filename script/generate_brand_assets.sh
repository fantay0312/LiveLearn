#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/build/brand-tools"
ICONSET="$ROOT/build/brand/LiveLearn.iconset"
ASSETS="$ROOT/Assets/Brand"
mkdir -p "$TOOLS" "$ASSETS"
swiftc "$ROOT/Sources/LiveLearnApp/DesignSystem/BrandGeometry.swift" \
  "$ROOT/script/generate_brand_assets.swift" -o "$TOOLS/generate-brand-assets"
"$TOOLS/generate-brand-assets" "$ASSETS" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ASSETS/AppIcon.icns"
