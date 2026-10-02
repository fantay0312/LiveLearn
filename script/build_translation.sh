#!/bin/zsh
# Compile the pinned GPL translation component. Called by build_and_run.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG=Debug
[[ "${1:-}" == "--release" ]] && CONFIG=Release
python3 "$ROOT/script/prepare_translation_runtime.py" > "$ROOT/build/translation-source-path.txt"
WORKSPACE="$ROOT/build/TranslationRuntime/Easydict.xcworkspace"
LOG="$ROOT/build/translation-build.log"
echo "▸ building native translation module ($CONFIG)"
if ! xcodebuild build -workspace "$WORKSPACE" -scheme Easydict -configuration "$CONFIG" \
    CODE_SIGNING_ALLOWED=NO EASYDICT_RELEASE_PACKAGING=YES > "$LOG" 2>&1; then
    rg -n 'error:|BUILD FAILED' "$LOG" | head -20 || true
    echo "✗ translation module failed; full log: $LOG"
    exit 1
fi
xcodebuild -showBuildSettings -json -workspace "$WORKSPACE" -scheme Easydict \
    -configuration "$CONFIG" -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO \
    > "$ROOT/build/translation-build-settings.json" 2> "$ROOT/build/translation-build-settings.log"
python3 - <<'PY'
from pathlib import Path
import json, shutil
root = Path.cwd()
settings = json.loads((root/'build/translation-build-settings.json').read_text())
target = next(item['buildSettings'] for item in settings if item.get('target') == 'Easydict')
source = Path(target['TARGET_BUILD_DIR']) / target['WRAPPER_NAME']
destination = root/'build/components/LiveLearnTranslation.app'
destination.parent.mkdir(parents=True, exist_ok=True)
if not (source/'Contents/MacOS/LiveLearnTranslation').is_file():
    raise RuntimeError('The translation helper executable is missing')
if destination.exists():
    shutil.rmtree(destination)
shutil.copytree(source, destination, symlinks=True)
shutil.copy2(root/'Assets/Brand/AppIcon.icns', destination/'Contents/Resources/AppIcon.icns')
licenses = destination/'Contents/Resources/LiveLearnSource'
licenses.mkdir(parents=True, exist_ok=True)
for name in ['LICENSE', 'SOURCE.json', 'README.livelearn.md', 'upstream.tar.gz']:
    shutil.copy2(root/'Vendor/Easydict'/name, licenses/name)
shutil.copytree(root/'Vendor/Easydict/Integration', licenses/'Integration', dirs_exist_ok=True)
shutil.copy2(root/'Sources/LiveLearnApp/Settings/UnifiedSettingsNavigation.swift', licenses/'UnifiedSettingsNavigation.swift')
shutil.copy2(root/'script/prepare_translation_runtime.py', licenses/'prepare_translation_runtime.py')
shutil.copy2(root/'script/translation_settings_presentation.py', licenses/'translation_settings_presentation.py')
shutil.copy2(root/'script/prepare_translation_settings.py', licenses/'prepare_translation_settings.py')
shutil.copy2(root/'script/build_translation_settings.sh', licenses/'build_translation_settings.sh')
PY
codesign --force --deep --sign - --identifier com.fantasy.livelearn.translation "$ROOT/build/components/LiveLearnTranslation.app" \
    > "$ROOT/build/translation-sign.log" 2>&1
codesign --verify --strict --deep "$ROOT/build/components/LiveLearnTranslation.app"
echo "  translation module built and signed"
zsh "$ROOT/script/build_translation_settings.sh" "$CONFIG"
