#!/usr/bin/env python3
"""Prepare the pinned Easydict source as LiveLearn's bundled native translation helper.

The pinned GPL source archive has local agent metadata and upstream service defaults removed.
Its published checksum and sanitization record live in SOURCE.json. Integration changes are applied
here or in Vendor/Easydict/Integration, so the helper can be rebuilt without an installed
Easydict or CocoaPods executable. No signing credentials or upstream release scripts run.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
import tarfile
from translation_settings_presentation import SETTINGS_PRESENTATION_PATHS, restyle_settings

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / 'Vendor/Easydict'
SOURCE = ROOT / 'build/TranslationSource'
RUNTIME = ROOT / 'build/TranslationRuntime'


def write_changed(path, data):
    if isinstance(data, str):
        data = data.encode()
    if not path.exists() or path.read_bytes() != data:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


def prepare():
    manifest = json.loads((VENDOR / 'SOURCE.json').read_text())
    archive = VENDOR / 'upstream.tar.gz'
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != manifest['sha256']:
        raise RuntimeError('The pinned Easydict source archive checksum does not match.')
    stamp = SOURCE / '.source-sha256'
    if not stamp.exists() or stamp.read_text() != digest:
        if SOURCE.exists():
            shutil.rmtree(SOURCE)
        SOURCE.mkdir(parents=True)
        with tarfile.open(archive, 'r:gz') as tar:
            for member in tar.getmembers():
                destination = (SOURCE / member.name).resolve()
                if not destination.is_relative_to(SOURCE.resolve()):
                    raise RuntimeError('Unsafe path in translation source archive')
            tar.extractall(SOURCE)
        stamp.write_text(digest)
    overlays = {
        'Easydict.xcodeproj/project.pbxproj', 'Easydict/App/EasydictApp.swift', 'Easydict/App/Info.plist',
        'Easydict/App/InfoPlist.xcstrings',
        'Easydict/Swift/Utility/Logging/AnalyticsService.swift',
        'Easydict/Swift/View/SettingView/Tabs/TabView/PrivacyTab.swift',
        'Easydict/Swift/Utility/GlobalContext.swift',
        'Easydict/Swift/View/SettingView/SettingView.swift',
        'Easydict/Swift/Feature/Shortcut/Model/ShortcutManager+Default.swift',
        'Easydict/objc/ViewController/Window/WindowManager/EZWindowManager.m',
        'Easydict/objc/ViewController/Window/WindowManager/EZWindowManager.h',
        'Easydict/Swift/View/SettingView/Tabs/TabView/GeneralTab.swift',
        'Easydict/Swift/Service/BuiltInAI/BuiltInAIService.swift',
        'Easydict/Swift/Service/AITool/AIToolService.swift',
        'Easydict/Swift/Service/Model/QueryServiceFactory.swift',
        'Easydict/objc/ViewController/Window/BaseQueryWindow/EZBaseQueryViewController.m',
        'Easydict/objc/ViewController/View/CustomButton/LanguageButton/EZDetectLanguageButton.m',
        'Easydict/objc/ViewController/View/ResultView/EZResultView.m',
    }
    overlays.update('Easydict/' + path for path in SETTINGS_PRESENTATION_PATHS)
    # Keep timestamps of unchanged generated inputs so Xcode's incremental build remains useful.
    for source in SOURCE.rglob('*'):
        if source.is_file():
            destination = RUNTIME / source.relative_to(SOURCE)
            if str(source.relative_to(SOURCE)) in overlays:
                continue
            if source.name == 'Package.resolved' and destination.exists():
                continue
            if source.name == 'EncryptedSecretKeys.plist':
                write_changed(destination, plistlib.dumps({}))
                continue
            write_changed(destination, source.read_bytes())
            destination.chmod(source.stat().st_mode & 0o777)

    project_path = 'Easydict.xcodeproj/project.pbxproj'
    project = json.loads(subprocess.check_output([
        'plutil', '-convert', 'json', '-o', '-', str(SOURCE / project_path)
    ]))
    objects = project['objects']
    target = objects['C99EEB172385796700FEE666']
    removed = {key for key, obj in objects.items()
               if obj.get('isa') == 'XCSwiftPackageProductDependency'
               and obj.get('productName') in {'FirebaseAnalytics', 'Sentry'}}
    for obj in objects.values():
        if 'packageProductDependencies' in obj:
            obj['packageProductDependencies'] = [x for x in obj['packageProductDependencies'] if x not in removed]
        if obj.get('isa') == 'PBXFrameworksBuildPhase':
            obj['files'] = [x for x in obj['files'] if objects[x].get('productRef') not in removed]
        if obj.get('isa') == 'PBXProject':
            obj['packageReferences'] = [x for x in obj.get('packageReferences', []) if not any(
                part in objects[x].get('repositoryURL', '')
                for part in ('firebase-ios-sdk', 'sentry-cocoa', 'SwiftLintPlugins')
            )]
    target['buildPhases'] = [x for x in target['buildPhases'] if objects[x].get('name') not in {
        'Format', 'Lint', 'Upload Debug Symbols to Sentry'
    }]
    objects[target['productReference']]['path'] = 'LiveLearnTranslation.app'
    for config in objects[target['buildConfigurationList']]['buildConfigurations']:
        objects[config]['buildSettings'].update({
            'PRODUCT_NAME': 'LiveLearnTranslation',
            'PRODUCT_BUNDLE_IDENTIFIER': 'com.fantasy.livelearn.translation',
            'INFOPLIST_FILE': 'Easydict/App/Info.plist',
            'ENABLE_DEBUG_DYLIB': 'NO',
            'CODE_SIGNING_ALLOWED': 'NO',
            'CODE_SIGN_ENTITLEMENTS': '',
            'CODE_SIGN_IDENTITY': '',
            'ASSETCATALOG_COMPILER_APPICON_NAME': '',
            'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/../Frameworks'],
        })
    write_changed(RUNTIME / project_path, plistlib.dumps(project))

    def edit(relative, transform):
        path = Path('Easydict') / relative
        write_changed(RUNTIME / path, transform((SOURCE / path).read_text()))

    def replace_once(text, before, after):
        if text.count(before) != 1:
            raise RuntimeError('Translation accessibility patch no longer matches the pinned source')
        return text.replace(before, after, 1)

    def accessible_detect_language(text):
        text = replace_once(text, '    self.alphaValue = 0;', '''    self.alphaValue = 0;
    self.accessibilityLabel = @"更正检测语言";
    self.accessibilityHelp = @"更正自动检测到的源语言";
    [self setAccessibilityHidden:YES];''')
        text = replace_once(text, '        [self setAnimatedHidden:YES];', '''        [self setAnimatedHidden:YES];
        [self setAccessibilityHidden:YES];''')
        text = replace_once(text, '    [self setAnimatedHidden:NO];', '''    [self setAnimatedHidden:NO];
    [self setAccessibilityHidden:NO];''')
        return replace_once(text, '    self.attributedTitle = attrTitle;', '''    self.attributedTitle = attrTitle;
    self.accessibilityLabel = fullTitle;''')

    def accessible_service_model(text):
        text = replace_once(text, '        self.serviceModelButton.title = model;', '''        self.serviceModelButton.hidden = NO;
        [self.serviceModelButton setAccessibilityHidden:NO];
        self.serviceModelButton.accessibilityLabel = [NSString stringWithFormat:@"选择模型：%@", model ?: @""];
        self.serviceModelButton.accessibilityHelp = @"选择此翻译服务使用的模型";
        self.serviceModelButton.title = model;''')
        return replace_once(text, '        self.serviceModelButton.title = @"";', '''        self.serviceModelButton.hidden = YES;
        [self.serviceModelButton setAccessibilityHidden:YES];
        self.serviceModelButton.title = @"";''')

    edit('objc/ViewController/View/CustomButton/LanguageButton/EZDetectLanguageButton.m', accessible_detect_language)
    edit('objc/ViewController/View/ResultView/EZResultView.m', accessible_service_model)

    settings_navigation = ROOT / 'Sources/LiveLearnApp/Settings/UnifiedSettingsNavigation.swift'
    app_sources = [VENDOR / 'Integration/EmbeddedTranslationApp.swift',
                   settings_navigation,
                   VENDOR / 'Integration/TranslationSettingsStyle.swift',
                   VENDOR / 'Integration/TranslationSettingsPicker.swift']
    write_changed(RUNTIME / 'Easydict/App/EasydictApp.swift', '\n'.join(path.read_text() for path in app_sources))
    write_changed(RUNTIME / 'Easydict/Swift/Utility/Logging/AnalyticsService.swift',
                  (VENDOR / 'Integration/AnalyticsService.swift').read_bytes())
    write_changed(RUNTIME / 'Easydict/Swift/View/SettingView/Tabs/TabView/PrivacyTab.swift',
                  (VENDOR / 'Integration/PrivacyTab.swift').read_bytes())
    edit('Swift/Utility/GlobalContext.swift', lambda s: s.replace('startingUpdater: true', 'startingUpdater: false'))
    write_changed(RUNTIME / 'Easydict/Swift/View/SettingView/SettingView.swift',
                  (VENDOR / 'Integration/TranslationSettingView.swift').read_bytes())
    for path in SETTINGS_PRESENTATION_PATHS:
        if not path.endswith('/GeneralTab.swift'):
            edit(path, lambda source, path=path: restyle_settings(path, source))
    edit('Swift/Feature/Shortcut/Model/ShortcutManager+Default.swift', lambda s: s.replace(
        'private func setDefaultAppShortcutKeys()', 'func setDefaultAppShortcutKeys()'))
    def window_manager(source):
        source = source.replace('NSApplicationActivationPolicyRegular', 'NSApplicationActivationPolicyAccessory').replace(
            'com_apple_SwiftUI_Settings_window', 'LiveLearnTranslation.settings')
        # Preserve native input/toggle behavior and place the workbench after its async layout.
        source = replace_once(source, '- (void)inputTranslate {', '''- (void)inputTranslate {
    [self inputTranslateWithCompletion:nil];
}

- (void)inputTranslateWithCompletion:(nullable void (^)(void))completionHandler {''')
        return replace_once(source, '''    self.actionType = EZActionTypeNone;
    [self showFloatingWindowType:windowType queryText:queryText];''', '''    self.actionType = EZActionTypeNone;
    self.windowType = windowType;
    CGPoint point = [self floatingWindowLocationWithType:windowType];
    [self showFloatingWindowType:windowType queryText:queryText actionType:self.actionType
                        atPoint:point completionHandler:completionHandler];''')

    edit('objc/ViewController/Window/WindowManager/EZWindowManager.m', window_manager)
    # Expose the existing OCR entry point to Swift without duplicating its window/reset logic.
    edit('objc/ViewController/Window/WindowManager/EZWindowManager.h', lambda s: replace_once(
        s, '#pragma mark - URL scheme', '''- (void)inputTranslateWithCompletion:(nullable void (^)(void))completionHandler
    NS_SWIFT_NAME(inputTranslate(completion:));

- (void)showFloatingWindowWithOCRImage:(NSImage *)image
                             autoQuery:(BOOL)autoQuery
                            actionType:(EZActionType)actionType
    NS_SWIFT_NAME(showFloatingWindow(withOCRImage:autoQuery:actionType:));

#pragma mark - URL scheme'''))

    # The helper is upgraded/launched with LiveLearn. Keep translation preferences while
    # removing controls that could install an independent login item or upstream updater.
    def general_settings(source):
        start = source.index('                // Check for updates')
        end = source.index('\n            } header:', start)
        updated = source[:start] + '                Text("翻译功能随 LiveLearn 一起启动和更新。")\n' + source[end:]
        return restyle_settings('Swift/View/SettingView/Tabs/TabView/GeneralTab.swift', updated)
    edit('Swift/View/SettingView/Tabs/TabView/GeneralTab.swift', general_settings)

    # Author-funded trial keys are not part of this fork. All service adapters remain,
    # while AI tools accept the user's own endpoint/model/key through their real settings.
    for path in (RUNTIME / 'Easydict').rglob('EncryptedSecretKeys.plist'):
        write_changed(path, plistlib.dumps({}))
    write_changed(RUNTIME / 'Easydict/Swift/Service/BuiltInAI/BuiltInAIService.swift',
                  (VENDOR / 'Integration/BuiltInAIService.swift').read_bytes())
    edit('Swift/Service/AITool/AIToolService.swift', lambda s: s.replace(
        'showAPIKeySection: false', 'showAPIKeySection: true').replace(
        'showEndpointSection: false', 'showEndpointSection: true').replace(
        'showSupportedModelsSection: false', 'showSupportedModelsSection: true').replace('.builtIn', '.userProvided'))
    edit('Swift/Service/Model/QueryServiceFactory.swift', lambda s: s.replace('apiKeyRequirement: .builtIn', 'apiKeyRequirement: .userProvided'))
    # Text handed over from captions, images or URLs is data. Preserve explicit typed
    # configuration commands in the workbench, but never execute them from an import.
    edit('objc/ViewController/Window/BaseQueryWindow/EZBaseQueryViewController.m', lambda s: s.replace(
        'if ([self handleEasydictScheme:text]) {',
        'if ([actionType isEqualToString:EZActionTypeInputQuery] && [self handleEasydictScheme:text]) {'))

    catalog = json.loads((SOURCE / 'Easydict/App/InfoPlist.xcstrings').read_text())
    for key in ['CFBundleDisplayName', 'CFBundleName']:
        for language, value in catalog['strings'][key]['localizations'].items():
            value['stringUnit']['value'] = 'LiveLearn 翻译' if language.startswith('zh') else 'LiveLearn Translation'
    for language, value in catalog['strings']['NSAppleEventsUsageDescription']['localizations'].items():
        value['stringUnit']['value'] = ('LiveLearn 翻译在取词、替换或系统翻译需要时使用自动化权限。'
            if language.startswith('zh') else 'LiveLearn Translation uses automation for selection, replacement and system translation.')
    write_changed(RUNTIME / 'Easydict/App/InfoPlist.xcstrings', json.dumps(catalog, ensure_ascii=False, indent=2))

    info = plistlib.loads((SOURCE / 'Easydict/App/Info.plist').read_bytes())
    for key in ['SUFeedURL', 'SUPublicEDKey', 'SUEnableAutomaticChecks', 'CFBundleURLTypes']:
        info.pop(key, None)
    info['CFBundleDisplayName'] = 'LiveLearn 翻译'
    info['CFBundleName'] = 'LiveLearn Translation'
    info['CFBundleIconFile'] = 'AppIcon'
    info['NSAppleEventsUsageDescription'] = 'LiveLearn 翻译仅在取词、替换或系统翻译需要时使用自动化权限。'
    info['LSUIElement'] = True
    info['SUEnableAutomaticChecks'] = False
    write_changed(RUNTIME / 'Easydict/App/Info.plist', plistlib.dumps(info))
    print(RUNTIME)


if __name__ == '__main__':
    prepare()
