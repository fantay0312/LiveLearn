#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-Debug}"
python3 script/prepare_translation_settings.py > build/translation-settings-source-path.txt
WORKSPACE="$ROOT/build/TranslationSettingsRuntime/Easydict.xcworkspace"
echo "▸ building embedded translation settings ($CONFIG)"
if ! xcodebuild build -workspace "$WORKSPACE" -scheme Easydict -configuration "$CONFIG" \
    CODE_SIGNING_ALLOWED=NO EASYDICT_RELEASE_PACKAGING=YES > build/translation-settings-build.log 2>&1; then
    rg -n 'error:|BUILD FAILED' build/translation-settings-build.log | head -20 || true
    exit 1
fi
xcodebuild -showBuildSettings -json -workspace "$WORKSPACE" -scheme Easydict -configuration "$CONFIG" \
    -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO \
    > build/translation-settings-build-settings.json 2> build/translation-settings-build-settings.log
python3 - <<'PY'
from pathlib import Path
import json, shutil
root = Path.cwd()
items = json.loads((root/'build/translation-settings-build-settings.json').read_text())
settings = next(item['buildSettings'] for item in items if item.get('target') == 'Easydict')
source = Path(settings['TARGET_BUILD_DIR']) / settings['WRAPPER_NAME']
destination = root/'build/components/LiveLearnTranslationSettings.bundle'
if not (source/'Contents/MacOS/LiveLearnTranslationSettings').is_file():
    raise RuntimeError('The native settings bundle is missing')
if destination.exists(): shutil.rmtree(destination)
shutil.copytree(source, destination, symlinks=True)
PY
codesign --force --deep --sign - "$ROOT/build/components/LiveLearnTranslationSettings.bundle" \
    > build/translation-settings-sign.log 2>&1
codesign --verify --strict --deep "$ROOT/build/components/LiveLearnTranslationSettings.bundle"
