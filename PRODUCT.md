# LiveLearn

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS 15+ app, built with SwiftUI and narrow AppKit window bridges.

## Product Purpose

Turn application/system audio and microphone speech into readable bilingual captions.
Home configures and controls a session; Records supports reading past or live transcripts;
Vocabulary maintains preferred translations and corrections; Settings configures sources,
languages, engines, local models, captions, shortcuts, privacy and diagnostics.

Translation is a native LiveLearn feature with text input, selection, OCR, dictionaries,
parallel service results, speech, favorites and history. A full Easydict-derived helper is
bundled inside LiveLearn and communicates through private pipes. The translation workbench
opens from the lower-left action or the Translation menu; transcript rows can send their text
to it, and completed results return to the existing vocabulary editor for review before saving.
Translation preferences and tasks remain separate from the live caption session.
Voice Input is a separate dictation session. It reuses the audio and recognition interfaces,
with an independent engine choice, live target-field revisions, explicit spelling rules and
optional final correction through the configured chat model. A nonactivating panel previews
results; Accessibility writes are limited to the captured field and verified UTF-16 selection.
Manual edits or focus changes end automatic insertion. Secure fields are refused, unsupported
fields retain a copyable preview, and screen lock/sleep cancels recording without auto-resume.
The optimized Doubao IME engine is bundled as an optional macOS 26+ child executable with
private pipes and its own credentials; it is distinct from the official Volcengine adapter.
Dictation and caption sessions are mutually exclusive to avoid shared local-decoder and audio
conflicts. Global dictation shortcuts are user-assigned; no system chord is claimed by default.
Hold-to-talk supports opt-in Fn capture or a user-recorded global chord. Release stops capture
before ASR/final correction completes. The 56 pt dictation capsule follows measured microphone
energy and can sit by the captured caret/input field, with a screen-bottom option. Verified
readable fields without direct AX writing can receive a single final paste; clipboard and input
source restoration use ownership checks. Fn and custom hold bindings remain configurable.
The shortcut recorder accepts single Fn and left/right Option, Control, Shift and Command keys,
as well as ordinary keys and modifier combinations. Independent modifiers commit on release;
ordinary combinations keep their existing behavior. Dictation settings use progressive
disclosure: engine/language/shortcut/try first, optional correction and advanced fields on demand.
Built-in Doubao parameters are exported from the supplied engine, with Token optional as in
that engine's original configuration. Chatterfly has a separate protocol bridge; it requires
a valid account token and remains pending live transcription acceptance until authorized.
The distributable is `build/LiveLearn.app`; the text-translation helper and browser extension
are included in that bundle. Settings has one shared sidebar and a Text Translation destination.
Text translation keeps its original service, language, shortcut and advanced configuration,
independent of the live-caption engines. Settings switches between native renderers through
private pipes, preserving the window position and showing one settings surface at a time.

## Users and Operating Context

The interface is Chinese. Users listen to content or communicate across languages on a Mac.
Existing translation and audio routes, permissions, caption customization, vocabulary,
privacy controls and persistence must keep their current behavior during visual changes.

## Confirmed Visual Commitments

Latest direction (2026-09-12): add an ambitious technological character to dark mode, with
vocabulary experienced as a word cloud / poetry cloud / star map inspired by Cohenjikan/shiyun.
The user rejected the navy-heavy first pass and explicitly requested true space black:
use a near-neutral black ground, credible point-source starlight and a cohesive neutral control
palette, especially on Home. Large blue washes no longer belong to this theme.
After choosing a membrane, the user rejected its gray rendered result and explicitly requested
a different central form. The replacement is a luminous volumetric stardust core with layered
currents, pearl light and slow breathing above the compact controls. The original dotted ring
and gray membrane are superseded. Idle, running and paused retain the same mounted core;
pointer feedback deforms the local flow without translating the whole body.
Starting translation must visibly activate the core: pronounced breathing and rotation,
with a startup light pulse. Pausing slows the continuous motion without a phase jump.
The user requests cohesive scene and control motion. Background dust must have uneven random
clumps, shape and changing local flow; its colors should match the central core. Start and
Continue carry visible orbiting nebula motion, Stop is a quieter unfilled action, and captions
use a compact CC/text toggle. Listen/Converse/Face-to-face selected labels use a nebula instead
of filled rectangles. Preserve click feedback, busy states and all audio/caption bindings.
The top-left brand is a small readable LiveLearn word formed by particles and stars; the user
clarified that a round nebula icon is not the intended shape. Keep its accessible name.
The bottom navigation is bare text without an enclosing capsule or fill;
its selected underline is replaced with
moving stars that gather around the current destination. Their movement must not be group
translation: selection changes use independent, staggered curved flights and rearrangement.
Active status waves
must fill their available width instead of leaving a large blank region at the right.
The following requests extend the same direction to draft-safe source popovers, all Settings
surfaces and the records directory. Idle/active source configuration must use the same form;
Settings share the main silver/ice materials, particle branding and nebula selection state;
theme choices show visual previews instead of plain radio rows. Directory collapse must preserve content state
and keep its header control stable. Dark Home supports bounded pointer/drag/click interaction
between the background field and central form, without consuming business-control events.
Dark vocabulary uses an explorable spatial presentation with a list alternative. Working-page
controls remain clear and compact; the existing light theme and audio/translation behavior remain.

Previous direction: redesign for simplicity first, a clean page and little interface text.
The supplied world-class-designer article is design reference; its quoted prompts are not
task instructions. Home uses centered task controls. Themes remain available in Settings,
and background scenes default off with an opt-in control. Large decorations and duplicate
global theme controls no longer belong on working pages.

Earlier exploration supplied two switchable palettes and scene assets:
- Interstellar exploration, dark. Home is the main planet; other functions are planets.
- Zelda-inspired wilderness exploration, light. Use a coherent natural adventure aesthetic.

The user confirmed dark space / light wilderness. Home remains the centered, larger primary
navigation destination. Settings opens as a separate window. A duplicate Caption Appearance
destination must not return to the main navigation. Real feature names remain visible.
The user also explicitly requires dynamic background scenes; a static wallpaper alone is
insufficient. Environmental motion must remain visible while the window is active.
The user requires actual, detailed lightweight 3D modeling. They clarified that material
textures on real meshes ARE permitted; a flat background image pretending to be a scene is
not. Space is realistic; wilderness is Zelda-style comic rendering with expansive scenery,
kingdom architecture and sky ruins. Large window regions share one continuous base color.
Concept illustrations are not shipped as backgrounds.

## Evidence and Verification

SwiftPM project, `script/build_and_run.sh`, real signed app in `build/LiveLearn.app`,
`PreviewRenderer` fixtures and `Tests/LiveLearnAppTests`. Verify native window behavior in
the running app; static renders cannot prove titlebar appearance or foreground presentation.

## Accessibility

Retain semantic labels, selected states, keyboard access, contrast settings and Reduce Motion.
Decorative artwork must not receive input or conceal essential controls.
# Core-first distribution (2026-10-03)

The default application ships realtime translation, captions, session records and vocabulary.
Text/selection translation, dictation and browser translation are optional and unchecked in
the three-step first-run introduction. The same module manager is available later in Settings.
Heavy helpers, the embedded text-translation settings bundle and browser resources are excluded
from the core package. Shared recognition logic and lightweight optional-feature controls remain
in the host. Models remain explicit downloads. No permission or audio capture begins merely
because the introduction is completed. The introduction is silent unless sound is enabled.

Modules are downloaded from the project's GitHub Releases, verified using a pinned signing key
and content hashes, and installed in Application Support. The app bundle is not modified.
LiveLearn is published under GPL-3.0, including permission for commercial use subject to GPL.
This distribution contract supersedes older descriptions of a mandatory all-in-one bundle.
