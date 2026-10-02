#!/bin/zsh
# Build the pinned local fork and its corresponding source. Never fetch at app runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/script/package_browser_extension.py"
