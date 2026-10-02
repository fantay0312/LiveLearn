#!/usr/bin/env python3
"""Build the pinned settings views as a loadable native component, with isolated preferences."""
from pathlib import Path
import json
import plistlib
import re
import subprocess
from prepare_translation_runtime import ROOT, write_changed

SOURCE = ROOT / 'build/TranslationRuntime'
DESTINATION = ROOT / 'build/TranslationSettingsRuntime'


def prepare():
    for path in SOURCE.rglob('*'):
        if path.is_file():
            target = DESTINATION / path.relative_to(SOURCE)
            write_changed(target, path.read_bytes())
            target.chmod(path.stat().st_mode & 0o777)

    project_path = DESTINATION / 'Easydict.xcodeproj/project.pbxproj'
    project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project_path)]))
    objects = project['objects']
    target = objects['C99EEB172385796700FEE666']
    target['productType'] = 'com.apple.product-type.bundle'
    objects[target['productReference']].update(path='LiveLearnTranslationSettings.bundle', explicitFileType='wrapper.cfbundle')
    for config in objects[target['buildConfigurationList']]['buildConfigurations']:
        settings = objects[config]['buildSettings']
        settings.update(PRODUCT_NAME='LiveLearnTranslationSettings', PRODUCT_MODULE_NAME='Easydict',
                        MACH_O_TYPE='mh_bundle', WRAPPER_EXTENSION='bundle', SKIP_INSTALL='YES',
                        GENERATE_PKGINFO_FILE='NO', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@loader_path/../Frameworks'])
    write_changed(project_path, plistlib.dumps(project))

    base = DESTINATION / 'Easydict'
    bridge = ROOT / 'Vendor/Easydict/Integration/TranslationSettingsBridge.swift'
    style = (ROOT / 'Vendor/Easydict/Integration/TranslationSettingsStyle.swift').read_text()
    style += '\n' + (ROOT / 'Vendor/Easydict/Integration/TranslationSettingsPicker.swift').read_text()
    style = style.replace('Text(', 'LLSettingsText(').replace('NSLocalizedString(', 'LLSettingsLocalizedString(')
    style = re.sub(r'\bString\(\s*localized:', 'LLSettingsString(localized:', style)
    entry = bridge.read_text() + '\n' + (ROOT / 'Sources/LiveLearnApp/Settings/UnifiedSettingsNavigation.swift').read_text() + '\n' + style
    write_changed(base / 'App/EasydictApp.swift', entry)
    info_path = base / 'App/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info.update(CFBundlePackageType='BNDL', NSPrincipalClass='LiveLearnTranslationSettingsController')
    info.pop('LSUIElement', None)
    write_changed(info_path, plistlib.dumps(info))

    # Redirect component-owned storage and resources, without altering the host's defaults or bundle.
    for path in base.rglob('*.swift'):
        if path == base / 'App/EasydictApp.swift':
            continue
        text = path.read_text()
        text = text.replace('UserDefaults.standard', 'TranslationSettingsResources.preferences')
        text = text.replace('Bundle.main', 'TranslationSettingsResources.bundle')
        text = re.sub(r'\b((?:Defaults\.)?Key<[^\n]+?>)\(', r'\1(translationKey: ', text)
        if path.name in {'Defaults.Keys+Extension.swift', 'ServiceConfigurationKey.swift', 'WindowConfigurationKey.swift'}:
            text = text.replace('return .init(key, default:', 'return .init(translationKey: key, default:')
        text = text.replace('NSLocalizedString(', 'LLSettingsLocalizedString(')
        text = re.sub(r'\bString\(\s*localized:', 'LLSettingsString(localized:', text)
        text = re.sub(r'(?<![\w.])Text\(', 'LLSettingsText(', text)
        text = re.sub(r'(\b(?:Toggle|Button|Label|Picker|Section|GroupBox|Menu|TextField|SecureField|Link)\(\s*)("(?:\\.|[^"\\])*")',
                      r'\1LLSettingsString(localized: \2)', text)
        text = re.sub(r'(\.(?:help|alert|confirmationDialog|accessibilityLabel)\(\s*)("(?:\\.|[^"\\])*")',
                      r'\1LLSettingsString(localized: \2)', text)
        text = text.replace('Image(type.rawValue)', 'Image(type.rawValue, bundle: TranslationSettingsResources.bundle)')
        if path.name == 'MyConfiguration.swift':
            text = text.replace('            observeKeys()', '            // Runtime observers remain in the query helper.')
        if path.name == 'LanguageState.swift':
            text = text.replace('@AppStorage(languagePreferenceLocalKey)',
                                '@AppStorage(languagePreferenceLocalKey, store: TranslationSettingsResources.preferences)')
        if path.name == 'ShortcutManager+Default.swift':
            start = text.index('        HotKeyCenter.shared.unregisterHotKey', text.index('func bindingGlobalShortcutAction'))
            end = text.index('\n    }', start)
            text = text[:start] + '        LiveLearnTranslationSettingsController.active?.preferencesChanged()' + text[end:]
        if path.name == 'KeyHolderWrapper.swift':
            for value in ['true', 'false']:
                original = 'MyConfiguration.shared.isRecordingSelectTextShortcutKey = ' + value
                text = text.replace(original, original + '\n            LiveLearnTranslationSettingsController.active?.eventHandler?(["action": "settings.recording", "text": "' + value + '"])')
        if path.name == 'FavoritesTab.swift':
            text = text.replace('windowManager.showFloating(windowType, queryText: record.queryText, autoQuery: true, actionType: .inputQuery)',
                'LiveLearnTranslationSettingsController.active?.eventHandler?(["action": "query", "text": record.queryText])')
            text = text.replace('        let windowType = Defaults[.shortcutSelectTranslateWindowType]\n', '')
            text = text.replace('        let windowManager = EZWindowManager.shared()\n', '')
        write_changed(path, text)

    localization = base / 'Swift/Feature/Localization/NSBundle+Localization.m'
    write_changed(localization, '''#import <Foundation/Foundation.h>
NSBundle *LLSettingsBundle(void) { return [NSBundle bundleForClass:NSClassFromString(@"LiveLearnTranslationSettingsController")]; }
NSUserDefaults *LLSettingsDefaults(void) { static NSUserDefaults *defaults; static dispatch_once_t once;
    dispatch_once(&once, ^{ defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.fantasy.livelearn.translation"]; }); return defaults; }
''')
    # Do not install process-wide description or WebKit swizzles when merely displaying settings.
    for relative in ['objc/Utility/PrintBeautifulLog/PrintBeautifulLog.m', 'objc/Service/WebViewTranslator/EZURLSchemeHandler.m']:
        path = base / relative
        text = path.read_text().replace('+ (void)load {', '+ (void)ll_unused_load {')
        write_changed(path, text)
    for path in base.rglob('*.m'):
        if path == localization:
            continue
        text = path.read_text().replace('NSBundle.mainBundle', 'LLSettingsBundle()')
        text = text.replace('[NSBundle mainBundle]', 'LLSettingsBundle()')
        text = text.replace('[NSUserDefaults standardUserDefaults]', 'LLSettingsDefaults()')
        text = '#import <Foundation/Foundation.h>\nextern NSBundle *LLSettingsBundle(void);\nextern NSUserDefaults *LLSettingsDefaults(void);\n' + text
        write_changed(path, text)
    print(DESTINATION)


if __name__ == '__main__':
    prepare()
