import tarfile
import unittest
from pathlib import Path

from translation_settings_presentation import restyle_settings

ROOT = Path(__file__).resolve().parent.parent


def original(name):
    with tarfile.open(ROOT / 'Vendor/Easydict/upstream.tar.gz') as archive:
        matches = [item for item in archive.getmembers() if item.isfile() and item.name.endswith('/' + name)]
        if len(matches) != 1:
            raise AssertionError(f'Expected one pinned source: {name}')
        return archive.extractfile(matches[0]).read().decode()


class PickerContracts(unittest.TestCase):
    def test_all_general_options_keep_original_collections(self):
        source = original('GeneralTab.swift')
        start = source.index('                // Check for updates')
        end = source.index('\n            } header:', start)
        source = source[:start] + '                Text("翻译功能随 LiveLearn 一起启动和更新。")\n' + source[end:]
        text = restyle_settings('GeneralTab.swift', source)
        self.assertEqual(text.count('TranslationSettingsPicker('), 6)
        for options in ['LanguageDetectOptimize.allCases', 'EnglishPronunciation.allCases',
                        'LanguageState.LanguageType.allCases', 'AppearanceType.allCases']:
            self.assertIn('options: ' + options, text)
        self.assertEqual(text.count('options: Language.allAvailableOptions'), 2)
        self.assertIn('languageDuplicatedAlert', text)

    def test_advanced_preserves_distinct_windows_disabled_state_and_height_notification(self):
        text = restyle_settings('AdvancedTab.swift', original('AdvancedTab.swift'))
        self.assertEqual(text.count('TranslationSettingsPicker('), 8)
        self.assertEqual(text.count('options: EZWindowType.availableOptions'), 2)
        self.assertNotIn('options: [EZWindowType]([.fixed, .mini, .main])', text)
        self.assertIn('.disabled(!autoShowQueryIcon)', text)
        self.assertIn('set: { maxWindowHeightPercentageValue = $0.rawValue }', text)
        self.assertIn('name: .maxWindowHeightSettingsChanged', text)

    def test_service_configuration_keeps_all_three_windows(self):
        text = restyle_settings('ServiceTab.swift', original('ServiceTab.swift'))
        self.assertEqual(text.count('TranslationSettingsPicker('), 1)
        self.assertIn('options: [EZWindowType]([.fixed, .mini, .main])', text)

    def test_both_generic_service_cells_use_live_values(self):
        text = restyle_settings('ServiceCells.swift', original('ServiceCells.swift'))
        self.assertEqual(text.count('options: values'), 2)
        self.assertIn('selection: $value', text)
        self.assertIn('selection: $selection', text)
        self.assertIn('@Default var values: [T]', text)

    def test_no_inline_native_menu_wrapper_remains(self):
        source = (ROOT / 'Vendor/Easydict/Integration/TranslationSettingsPicker.swift').read_text()
        self.assertNotIn('.pickerStyle(.inline)', source)
        self.assertNotIn('Menu(content:', source)
        self.assertIn('options: [""] + groups', source)


if __name__ == '__main__':
    unittest.main()
