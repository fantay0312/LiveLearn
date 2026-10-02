# Easydict translation component

This directory contains the buildable upstream source archive pinned in `SOURCE.json`,
its GPL-3.0 license, and the source overlays used by LiveLearn.
Local agent metadata is excluded and upstream service configuration plists are empty;
`SOURCE.json` records both the original and sanitized archive hashes.

`script/prepare_translation_runtime.py` verifies the archive and prepares a native Xcode
application target. `script/build_translation.sh` compiles that target. The default core
build excludes it. The optional text-translation download contains both the helper and
the settings bundle, installed under LiveLearn's Application Support/Modules directory.

The helper retains the complete translation, dictionary, OCR, selection, TTS, history,
favorites, settings and automation implementation. It runs as a child of LiveLearn with
private inherited pipes; it does not require an Easydict installation or an IPC web server.
The helper has its own preferences domain and exits when the parent closes the command pipe.

Integration changes replace the standalone entry point, expose internal commands and results,
remove the extra menu-bar item, leave the Dock identity with LiveLearn, and route settings through
the shared LiveLearn sidebar. `LiveLearnTranslationSettings.bundle` loads the original settings
views into a host-owned `NSViewController` inside the main window; it creates no settings panel.
The original eight text-translation settings pages retain
their values, bindings and actions inside the shared shell. Settings-only adapters give forms,
menus, switches, service lists and editors LiveLearn's typography and neutral surfaces.
The original TabView still owns page selection and lifecycle; an AppKit bridge removes only
its standard navigation chrome. Only the host owns the settings panel size; Easydict's
standalone settings-window resizing is not applied. The shell's theme does not overwrite
text-translation appearance preferences. The presentation transforms are isolated in
`script/translation_settings_presentation.py` and shipped with the corresponding source.
The Translation entry invokes Easydict's original input-translation action. Queries and images
use its configured shortcut window type, original sizing, pinning, dismissal and query palette.
Saved services and preferences are preserved; fresh service lists use upstream defaults.
The shared navigation source is `Sources/LiveLearnApp/Settings/UnifiedSettingsNavigation.swift`
and is included alongside the overlays in the packaged corresponding source.
`script/prepare_translation_settings.py` builds the settings bundle from the same pinned and
adapted source. Its defaults keys, direct defaults access and AppStorage use the existing
`com.fantasy.livelearn.translation` domain. Resources and localization are bundle-scoped;
loading settings never replaces the host's main bundle class or installs upstream WebKit or
collection-description swizzles. Runtime observers and global shortcuts stay in the query
helper. Changes notify it over the private pipe so its original configuration observers,
services and shortcuts refresh without restarting a query window. The native integration
check uses disposable preference domains: `zsh script/verify_translation_settings.sh`.
Settings now share the host's sidebar, background, focus, resizing, minimization and screenshot
behavior. The original translation query windows remain in the helper and are unchanged.
The intermediate helper is built under `build/components`; distribute it through the signed module catalog.
Upstream release/upload scripts do not run. Firebase/Sentry,
independent update checks, independent login items and author-funded trial keys are excluded.
The corresponding services and AI tools remain configurable with the user's own account.

This is a GPL component, not a permissively licensed rewrite. Process isolation protects
application state; it is not a claim that license obligations disappear. LiveLearn is
distributed under GPL-3.0 with corresponding source and original dependency notices.
Original notices are present in the archive and are shipped with the helper.
