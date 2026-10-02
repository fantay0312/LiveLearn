#!/bin/zsh
# Native integration check; no keyboard/mouse injection and no real preferences are edited.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${1:-tmp/translation-settings-verification}"
python3 - "$OUT" "${2:-build/components}" <<'PY'
from pathlib import Path
import plistlib, shutil, subprocess, sys, uuid
directory = Path(sys.argv[1]).resolve()
directory.mkdir(parents=True, exist_ok=True)
suite = 'com.fantasy.livelearn.testing.' + str(uuid.uuid4())
component_root = Path(sys.argv[2])
for source, name in [
    (component_root/'LiveLearnTranslationSettings.bundle', 'Settings.bundle'),
    (component_root/'LiveLearnTranslation.app', 'Translation.app'),
]:
    if not source.exists():
        source = component_root/('PlugIns' if name == 'Settings.bundle' else 'Helpers')/source.name
    if not source.exists():
        raise SystemExit('Build the optional text-translation module first.')
    destination = directory/name
    if destination.exists(): shutil.rmtree(destination)
    subprocess.run(['cp', '-cR', source, str(destination)], check=True)
    path = destination/'Contents/Info.plist'
    info = plistlib.loads(path.read_bytes())
    info['CFBundleIdentifier'] = suite
    path.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', '--identifier', suite, str(destination)], check=True, capture_output=True)
PY
swift script/verify_translation_settings.swift "$OUT/Settings.bundle" \
    "$OUT/Translation.app/Contents/MacOS/LiveLearnTranslation" "$OUT/result.json" > "$OUT/probe.log" 2>&1
cat "$OUT/result.json"
