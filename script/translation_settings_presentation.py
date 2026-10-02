"""Presentation-only transforms for the pinned Easydict settings views."""
import re
import textwrap

SETTINGS_ROOT = 'Swift/View/SettingView/'
SETTINGS_PRESENTATION_PATHS = [
    SETTINGS_ROOT + 'Tabs/TabView/' + name + '.swift'
    for name in ['GeneralTab', 'ServiceTab', 'FavoritesTab', 'DisabledAppTab', 'ShortcutTab', 'AdvancedTab', 'AboutTab', 'ServiceTabListViews']
] + [
    SETTINGS_ROOT + 'Tabs/View/WindowConfigurationView.swift',
    SETTINGS_ROOT + 'Tabs/ServiceConfigurationView/ServiceCells.swift',
    SETTINGS_ROOT + 'Tabs/ServiceConfigurationView/StreamConfigurationView.swift',
    SETTINGS_ROOT + 'Tabs/ServiceConfigurationView/TextEditorCell.swift',
    'Swift/View/AdvancedTabItemView.swift',
    'Swift/Feature/Shortcut/View/KeyHolderRowView.swift',
    'Swift/Service/Dictionary/MDict/MDictConfigurationView.swift',
]


def replace(text, before, after, count=1):
    if text.count(before) != count:
        raise RuntimeError('Pinned settings presentation changed: ' + before[:90])
    return text.replace(before, after)


def closing_delimiter(text, start, opening, closing):
    depth = 0
    quoted = False
    escaped = False
    for index in range(start, len(text)):
        char = text[index]
        if quoted:
            if escaped:
                escaped = False
            elif char == '\\':
                escaped = True
            elif char == '"':
                quoted = False
            continue
        if char == '"':
            quoted = True
        elif char == opening:
            depth += 1
        elif char == closing:
            depth -= 1
            if depth == 0:
                return index
    raise RuntimeError('Unbalanced pinned picker content')


def explicit_picker_options(text):
    cursor = 0
    while (start := text.find('TranslationSettingsPicker(', cursor)) >= 0:
        arguments_start = start + len('TranslationSettingsPicker')
        arguments_end = closing_delimiter(text, arguments_start, '(', ')')
        body_start = text.index('{', arguments_end)
        body_end = closing_delimiter(text, body_start, '{', '}')
        body = text[body_start + 1:body_end]
        match = re.match(r'\s*ForEach\(', body)
        if not match:
            raise RuntimeError('Pinned picker must declare its exact options in ForEach')
        list_start = match.end() - 1
        list_end = closing_delimiter(body, list_start, '(', ')')
        options = re.split(r',\s*id:', body[list_start + 1:list_end])[0].strip()
        row_start = body.index('{', list_end)
        row_end = closing_delimiter(body, row_start, '{', '}')
        row = body[row_start + 1:row_end]
        variable = re.match(r'\s*(\w+)\s+in', row)
        if not variable:
            raise RuntimeError('Pinned picker has an unsupported row builder')
        name = variable.group(1)
        label = replace(row[variable.end():], '.tag(' + name + ')', '').rstrip()
        # Keep content lifecycle effects on the picker itself, including the height notification.
        effects = body[row_end + 1:].rstrip()
        arguments = text[arguments_start + 1:arguments_end].rstrip().rstrip(',')
        indent = text[text.rfind('\n', 0, start) + 1:start]
        label = textwrap.dedent(label).strip()
        row = '\n'.join(indent + '    ' + line for line in label.splitlines())
        replacement = 'TranslationSettingsPicker(' + arguments + ', options: ' + options + ') { ' + name + ' in\n' + row + '\n' + indent + '}' + effects
        text = text[:start] + replacement + text[body_end + 1:]
        cursor = start + len(replacement)
    return text


def restyle_settings(path, source):
    name = path.rsplit('/', 1)[-1]
    text = source.replace('.formStyle(.grouped)', '.formStyle(TranslationSettingsFormStyle())')
    if name in {'GeneralTab.swift', 'AdvancedTab.swift', 'ShortcutTab.swift', 'WindowConfigurationView.swift', 'ServiceCells.swift'}:
        text = re.sub(r'\bPicker\(', 'TranslationSettingsPicker(', text)

    if name == 'AdvancedTab.swift':
        text = replace(text, 'selection: $maxWindowHeightPercentageValue,',
            '''selection: Binding(get: { MaxWindowHeightPercentageOption(rawValue: maxWindowHeightPercentageValue) ?? .defaultOption },
                                       set: { maxWindowHeightPercentageValue = $0.rawValue }),''')

    if name == 'ServiceCells.swift':
        text = replace(text, 'Text(value.title)', 'Text(value.title).tag(value)', count=2)
        text = replace(text,
            '        SecureTextField(title: textFieldTitleKey, placeholder: placeholder, text: $value, showText: showText)',
            '''        TranslationSettingsField(title: textFieldTitleKey) {
            SecureTextField(title: textFieldTitleKey, placeholder: placeholder, text: $value, showText: showText)
        }''')
        text = replace(text, '''        TextField(textFieldTitleKey, text: $value, prompt: Text(placeholder))
            .onReceive(Just(value)) { _ in
                limit(limitLength)
            }''', '''        TranslationSettingsField(title: textFieldTitleKey) {
            TextField(textFieldTitleKey, text: $value, prompt: Text(placeholder))
                .onReceive(Just(value)) { _ in
                    limit(limitLength)
                }
        }''')

    if name in {'ServiceTab.swift', 'FavoritesTab.swift', 'DisabledAppTab.swift'}:
        text = replace(text, '.borderedCard()', '.scrollContentBackground(.hidden)')
    if name == 'ServiceTab.swift':
        text = replace(text, '.frame(minWidth: 270, maxWidth: 320, maxHeight: .infinity)',
                       '.frame(minWidth: 280, idealWidth: 280, maxWidth: 320, maxHeight: .infinity)')
        text = replace(text, '.listStyle(.plain)',
                       '.listStyle(.plain)\n                    .background(TranslationSettingsListChrome())')
        text = replace(text, 'private struct WindowConfigurationItem: View {',
                       'private struct WindowConfigurationItem: View {\n    @EnvironmentObject private var viewModel: ServiceTabViewModel')
        text = replace(text, '            .padding(.vertical, 8)',
                       '            .padding(.vertical, 12)\n            .modifier(TranslationSettingsSelection(selected: viewModel.selectedItems.contains(.windowConfiguration)))')
        text = replace(text, '        Picker(selection: $windowType) {',
                       '        TranslationSettingsPicker(selection: $windowType) {')
        text = replace(text, '.pickerStyle(.segmented)', '.accessibilityLabel("配置窗口")')
    if name == 'DisabledAppTab.swift':
        text = replace(text, '.background(Color("add_minus_bg_color"))', '.background(Color.clear)')
        text = replace(text, '.padding(.top, 18)', '.padding(.top, 26)')
    if name == 'FavoritesTab.swift':
        start = text.index('            Picker(selection: $selectedSection)')
        end = text.index('\n\n            // Header', start)
        text = text[:start] + '''            HStack(spacing: 20) {
                Button("history.tab") { selectedSection = .history }
                    .buttonStyle(TranslationSettingsActionStyle(selected: selectedSection == .history))
                    .accessibilityAddTraits(selectedSection == .history ? .isSelected : [])
                Button("favorites.tab") { selectedSection = .favorites }
                    .buttonStyle(TranslationSettingsActionStyle(selected: selectedSection == .favorites))
                    .accessibilityAddTraits(selectedSection == .favorites ? .isSelected : [])
                Spacer()
            }
            .frame(height: 28).padding(.horizontal)
''' + text[end:]
        text = replace(text, '.font(.system(size: 48))', '.font(.system(size: 28, weight: .light))')
        text = replace(text, '.padding(20)', '.padding(.horizontal, 8).padding(.vertical, 20)')
    if name == 'AdvancedTabItemView.swift':
        start = text.index('            Rectangle()')
        end = text.index('\n\n            VStack', start)
        text = text[:start] + '''            Image(systemSymbol: icon)
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 20).accessibilityHidden(true)''' + text[end:]
        text = replace(text, 'VStack(alignment: .leading, spacing: 8)', 'VStack(alignment: .leading, spacing: 4)')
        text = replace(text, '.font(.subheadline)', '.font(.system(size: 11))')
    if name == 'KeyHolderRowView.swift':
        text = replace(text, '.borderedCard()', '.modifier(TranslationSettingsInputSurface())')
    if name == 'TextEditorCell.swift':
        text = replace(text, '''            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(NSColor.separatorColor), lineWidth: 1))''',
                       '            .modifier(TranslationSettingsInputSurface())')
        text = replace(text, '.font(.body)', '.font(.system(size: 13))')
    if name == 'AboutTab.swift':
        text = replace(text, '.frame(width: 100, height: 100)', '.frame(width: 64, height: 64)')
        text = replace(text, '.font(.system(size: 35, weight: .medium))', '.font(.system(size: 24, weight: .regular))')
        text = text.replace('.foregroundColor(.gray)', '.foregroundStyle(.secondary)')
        text = replace(text, '.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)',
                       '.padding(.horizontal, 24).padding(.top, 40)\n        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)')
    if name == 'ServiceTabListViews.swift':
        text = replace(text, '''                Text(verbatim: item.name)
                    .lineLimit(1)
                    .truncationMode(.tail)''', '''                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.name).lineLimit(1).truncationMode(.tail)
                    Text(verbatim: ServiceRequirementBadge.title(for: item.requirement))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }''', count=2)
        text = replace(text, '            ServiceRequirementBadge(requirement: item.requirement)\n', '')
        text = replace(text, '        .padding(.vertical, 8)',
                       '        .padding(.vertical, 9)\n        .modifier(TranslationSettingsSelection(selected: viewModel.selectedItems.contains(.service(item.id))))')
        text = text.replace('"no-key"', '"无需密钥"').replace('"built-in"', '"内置服务"').replace('"key"', '"需要密钥"').replace('"cli"', '"本机命令行"')
        text = replace(text, '.toggleStyle(.switch)', '.toggleStyle(TranslationSettingsToggleStyle(showsLabel: false))')
        text = replace(text, '.frame(width: 640, height: 540)',
                       '.frame(width: 640, height: 540)\n        .modifier(TranslationSettingsSheetStyle())')
        text = replace(text, '.fill(Color(nsColor: .controlBackgroundColor))', '.fill(Color.primary.opacity(0.035))')
        text = replace(text, '.fill(.primary.opacity(isSelected || isHovered ? 0.08 : 0))',
                       '.fill(.primary.opacity(isSelected ? 0.14 : isHovered ? 0.07 : 0))')
        text = replace(text, '.buttonStyle(.plain)', '.buttonStyle(TranslationSettingsPressStyle())')
        start = text.index('private struct ServiceListControl: NSViewRepresentable')
        end = text.index('// MARK: - AddServiceSheet', start)
        text = text[:start] + '''private struct ServiceListControl: View {
    let canRemove: Bool
    let addAction: () -> ()
    let removeAction: () -> ()
    var body: some View {
        HStack(spacing: 16) {
            Button(action: addAction) {
                Label("setting.service.add", systemImage: "plus").font(.system(size: 11))
            }
            Button(action: removeAction) {
                Image(systemName: "minus").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .disabled(!canRemove).help("setting.service.remove")
            .accessibilityLabel("setting.service.remove")
        }
        .buttonStyle(TranslationSettingsActionStyle())
    }
}

''' + text[end:]
    if name == 'StreamConfigurationView.swift':
        start = text.index('                    Picker(selection: $selectedGroup)')
        end = text.index('\n                }', start)
        text = text[:start] + '''                    TranslationModelGroupMenu(selection: $selectedGroup, groups: modelGroups)
                        .frame(width: 140, alignment: .leading)''' + text[end:]
        text = replace(text, '.textFieldStyle(.roundedBorder)', '.textFieldStyle(TranslationSettingsTextFieldStyle())')
        text = replace(text, '.frame(width: 520, height: 440)',
                       '.frame(width: 520, height: 440)\n        .modifier(TranslationSettingsSheetStyle())')
    if name == 'MDictConfigurationView.swift':
        # An explicit List retains the upstream reorder/delete gestures inside the custom form.
        start = text.index('            ForEach(manager.records)')
        end = text.index('\n        } header:', start)
        rows = text[start:end]
        text = text[:start] + '''            if !manager.records.isEmpty {
                List {
''' + '\n'.join('        ' + line for line in rows.splitlines()) + '''
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .frame(height: CGFloat(min(5, manager.records.count) * 56))
            }''' + text[end:]
        text = replace(text, '.toggleStyle(.switch)',
                       '.toggleStyle(TranslationSettingsToggleStyle(showsLabel: false))\n            .accessibilityLabel(record.title)')
    return explicit_picker_options(text)
