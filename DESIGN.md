# LiveLearn — Quiet operation, stellar vocabulary

## One Star Chart (2026-09-27)

The user asked (verbatim): "帮我们这个项目外观做一个深度优化，大胆设计。保持风格，旨在更优美" — a deep,
bold refinement of the appearance that keeps the style and aims for more beauty. The diagnosis:
each surface was individually close, but the app was not one object — eight "selected" markers,
five button grammars, three sidebar systems, six radii and three field styles. Records and
Vocabulary had drifted back to patterns the user had already rejected (icon lists, filled
selection slabs, a solid ice button, an outlined transport card, boxed search, a boxed segmented
control with a ✨, centred icon + title + button empty states). Home was a loose stack whose
capsule jumped 52 pt off-axis when a session started, and every PaperMenu glyph cast the sheet's
shadow.

The answer is one system: the whole app is one observatory star chart, and light comes only from
points. Three marks are used everywhere and never mixed:
- **Orbit** — where you are. The dust ring of the bottom navigation and of Home's mode row,
  nothing else. (The primary capsule's moving edge nebula and Stop's quieter stars are recorded
  earlier as the action's own light and stay.)
- **Star point** — what you chose. One stamped recipe, `SettingsStarPoint`: in the dark a 1.4 pt
  core, two 0.5 pt rays at ± 2.2 pt and a 4 pt halo; on paper a 3.2 pt forest core with hairline
  rays at ± 3.4 pt at half strength and no halo; plain ink under Increase Contrast. The host's
  `StarMark` wraps that recipe (a vocabulary class hue is painted through the shared star's own
  coverage), so it exists once in both processes. It marks every rail (settings, records,
  vocabulary), every segment and word choice, PaperMenu single-choice rows and ticked check rows,
  presets, the theme, every word toggle that is on, and draft values that 应用 would change. It is
  stamped, never faded in, and never changes layout.
- **Now bar** — live, this moment. The 2 pt accent `NowMark` on the live rail row, the open
  transcript line and the menu-bar status.

No selection is a fill, in either theme. Selected text also goes to full `ink`, so no state relies
on the mark alone; Differentiate Without Color keeps its underline.

Three action tiers, and only three:
1. **Stellar capsule.** Home's primary: the almost-clear breathing capsule. Its static compact
   variant (`CompactCapsuleButtonStyle`: 32 pt tall, label 13/500 `accent`; dark body `ink` 3 %,
   a 0.75 pt rim lit from the top arc, 18 → 12 → 6 %, and 22 still grains gathered on the upper
   shoulders; paper a forest label, forest rim 25 → 18 %, forest 5 % body and no dust; disabled an
   `ink3` 60 % label and an even 4 % rim, never a grey slab; Increase Contrast an even 1 pt `ink`
   rim at 45 %; no clock) is the single commit of a sheet or popover — the vocabulary editor's and
   importer's 添加 / 保存, the active source editor's 应用并重新开始.
2. **Text action.** Everything else: a word in `ink2` lifting to `ink`. The one way forward under a
   sentence (an empty or no-result state, the source-check remedy) is the strong word,
   `TextButtonStyle(strong:)`: 13/500 `ink` at rest, answering the pointer with the settings'
   neutral interaction light, since an `ink` word cannot lift. Settings actions
   (`SettingsActionStyle`) are the same strong word.
3. **Glyph action.** A bare regular-weight SF Symbol (`GlyphButtonStyle`) with at least a 28 pt hit
   area.

Every solid-ice slab, outlined button and graphite-filled slab is gone (`AccentButtonStyle`,
`QuietButtonStyle`, `ActionEmptyState`, `DictionaryButtonStyle`, `CheckMark`, `SelectionDot` and
`RowButtonStyle`'s selected fill no longer exist). Word toggles — 字幕 / 锁定 on the horizon, 目录 in
the window header, 开发者模式 at the settings rail foot, 字幕 on Home — are `ink` with a star stamped
under the word when on and full `ink3` when off (`TextToggleStyle`, `TextToggleButtonStyle`; the
rail foot's `RailWordToggleStyle` and Home's caption toggle draw the same); the star is an
overlay, so nothing moves. The old off state, `ink3` at 60 %, measured about 3:1 and is
retired.

Edges: every separator is a 0.5 pt hairline whose ends fade (`FadingRule`, trailing or both ends;
`SettingsRule` is `FadingRule()`). In-window structures — search, transport, lists — have no edge
and no fill. Search is `BareSearchField`: a 13 pt magnifier and placeholder on the ground over a
fading underline that becomes 1 pt `ink2` when focused, with no system ring except under Increase
Contrast. Floating things share one material (`floatingPaper`, `LLTheme.floatingEdge`): in the dark
`surface` with a top-lit edge, `ink` 16 % at the top → 7 % → 3 %, and no shadow; on paper `surface`,
a `hairline` and one soft shadow cast by the sheet's shape alone; under Increase Contrast an even
`hairline`. PaperMenu sheets and the settings card use it; popover bodies stay on the near-black
ground.

Type is one scale with no bold: 11 for labels and facts · 13 for UI and body · 15 for the hero
action label, rail headers and popover values · 17/500 for sheet, popover and window titles ·
24/400 for opening lines (the settings page title, empty-state openings, the record masthead).
Home's route values are 14 so that a converse sentence fits the mode row's 264 pt. Overlay sizes
and the navigation's recorded sizes (首页 larger) are unchanged. The CC glyph (12/500) and the
7.5 pt chevrons are glyph sizes, off the text scale on purpose. Configuration values are quieter
than the action (`ink2`) and brighten on hover or open. A running clock reads m:ss under an hour
and h:mm:ss above, in monospaced digits, everywhere (`StatusCopy.clock`).

Boundaries kept from recorded decisions: the dark ground stays #030405 and light comes only from
points; the core keeps its volumetric form, 6,400 grains and 210–360 pt (its material changed, not
its form); the primary capsule stays the breathing capsule with its moving edge nebula; the caption
switch stays a compact CC/text toggle bound to `overlayVisible`; the navigation stays bare text
with its 192-grain dust and 首页 larger; the wilds theme keeps its palette, no sky, and a list for
Vocabulary; the settings rail's 36/32 pt table, the 576 pt measure and the round-11 control axis
stay; no behaviour, data path, shortcut or preference changed, and errors, cost and permission notes
stay visible. No new clock or live canvas was added; every new mark is static, and every particle
change is made in Canvas and Metal constant for constant under the parity gate. The caption
overlay and the dictation capsule are out of scope by decision (a dictation redesign needs the
user's confirmation).

Rejected or not taken this round, and why:
- A box around multi-select check rows (a review proposal): the user asked in round 4 never to put
  outlines back on checkboxes. An unticked check row is a 6 pt ring, a ticked one the lit star; a
  lit star inside a faint ring was tried and dropped because it reads as a radio or a crosshair. A
  ticked check row therefore looks like a chosen single-choice row; VoiceOver still says
  已勾选 / 未勾选.
- An orbit on Home's 停止 (a review finding): Stop stays an unfilled text action with quieter stars.
- Growing the core past 360 pt or widening its rim: outside the recorded 210–360 pt range; the
  visible core is about 242 pt at the default window.
- A default-contrast edge on the dark switch track: it contradicts "state in the track, no ring";
  the user declined it on 2026-09-28. Only Increase Contrast adds edges.
- 目录 as a `Toggle`: it stays a button (显示 / 收起记录栏, 展开 / 收起, ⌘⇧L) that wears the word-toggle
  look.
- A settings help "?" directly after its label: after CJK text it read as punctuation, so it sits
  at the rag of the label's line.
- Optional bold moves left as follow-ups: a map ↔ list morph, dimming the stars a rail row does not
  match, pack constellations, a page-switch sky pan, a light star atlas, an asymmetric recomposition
  of the background field's arms.

## Settings modes and caption reading (2026-09-20)

Settings keeps the existing in-window surface and both theme palettes. Its sidebar starts
directly with Sources, Languages and Caption Appearance; there is no “实时字幕” heading.
Translation/Input groups dictation, text translation and browser translation. Services/Models
groups engine configuration and local downloads. App Preferences groups theme, shortcuts and
privacy. Developer diagnostics follows those groups only in Developer mode.

The ordinary-user/developer switch stays at the bottom of the sidebar, outside its independent
scroll region: since round 12 one word toggle, 开发者模式 (on `ink` with the star point stamped under
the word, the mark every on word carries; off `ink3` at full opacity; the rail rows' light and
press; VoiceOver reads a switch), with an 11 pt `ink3` line 5 pt under it and a fading rule above.
The boxed 普通用户 / 开发者 capsule is gone. The list is clipped at that rule and nothing is drawn
under it; where the card cuts the list, the cut dissolves over a 24 pt band that ends on the rule,
grading the last name it reaches from full ink to about half. The selected page always opens clear
of the band, and a selection moved onto a cut row scrolls the list only as far as clears it. The
band's mask exists only while the list overflows (at 960 × 600, not at 1180 × 760).
Ordinary mode is the default. Switching modes persists only presentation mode;
it never resets service choices, addresses, credentials or tuning. Engine choice, necessary
model names, credentials, custom/local addresses, model downloads and recovery remain reachable.
Default endpoint overrides, compatibility protocol, partial-cloud-translation tuning, active
translation probes and channel metrics belong to Developer mode. Ordinary users can export a
diagnostic package from Privacy. The embedded translation settings component receives the mode
explicitly; ordinary mode hides Advanced while Developer mode retains all original sections.

Caption overlays are a reading window over the complete transcript: a prominent current
sentence, optional muted previous sentence, and smaller incoming preview. The current primary
text occupies one focused reading line; context and source lines stay compact. Long paragraphs use recent
sentence units; unpunctuated text uses a grapheme-safe trailing excerpt. Source text never appears
when Show Source is disabled. Sentence pairing is only projected when current bilingual sentence
counts agree; stale or mismatched translations remain a single segment. The underlying transcript,
correction history, exports and archive are never shortened for this presentation.

Caption Presentation offers Layered and Single-line Subtitles in Appearance settings and the
caption style menu. Layered preserves the reading window above. Single-line Subtitles shows one
translated line, including when both audio lanes are active; the latest translated lane wins.
While translation is pending, the previous translation stays visible. It does not add source,
history or breathing rows. Those preferences remain saved for switching back to Layered.
Each mode remembers its own width (880 pt layered, 640 pt single-line by default). Following
the user's YouTube clarification, text stays stationary and changes one cue at a time; there
is no horizontal scroll or transition. Long sentences split at word/clause or grapheme
boundaries using measured font widths, and advance at a reading pace. Pausing holds the cue.
The panel height and position stay stable; complete translations remain in the transcript.

The 2026-09-21 clarification preserves the existing background, palette, toolbar and window
chrome. Only text presentation follows the supplied reference. Reserve stable slots for prior,
current and incoming cues; split continuous unpunctuated input at word/clause or grapheme
boundaries instead of letting it fill a paragraph. Automatic contrast samples a small region
behind the caption and uses solid dark-gray ink over bright content, restoring the saved ink
over dark content. Two consecutive samples outside a dead band switch the ink; no hard outline
is added. Screen access is checked before sampling and only local brightness values survive.
Stronger system contrast may lift context opacity. The user's background and type preferences
are not reset by this refinement.

Window Server owns overlay dragging. During a drag, caption-height updates are retained but do
not reset the window frame. On release, the controller adopts the actual position, applies the
latest size, and saves the location once. Position persistence must never run for every move or
for programmatic caption-height changes.

Working pages prioritize clean content, little interface text and clear actions. The 2026-09-12
direction adds a stronger technological character to the dark theme and an explorable vocabulary
star map, inspired by the spatial content metaphor in Cohenjikan/shiyun.

## Structure

Home is one instrument on one axis: the stardust core, the primary capsule, the mode row and the
configuration sentence, stacked in that order and centred in the band between the wordmark row
and the dock (lifted 4 pt above the centre of what is seen). No promotional heading or subtitle
competes with it. An active session keeps the same shape: the capsule stays where it was, the mode
row's slot carries the status line (state · clock and the caption toggle), and each audio route is
one configuration line. `HomeComposition` (ParticleMath) is the single source of this composition,
for the page layout and for every particle constant that keeps the operating area dark.

Home remains centered in the bottom navigation and slightly larger than Records and Vocabulary.
Settings opens as a centered modal inside the main window, reached by its gear or Command-comma.
The current page remains behind a dimmed, blurred backdrop. The modal has a category sidebar,
scrolling content and a close ✕ on the sidebar's brand line; Escape, Command-W and clicking the backdrop
also dismiss it. It has no separate title bar or traffic-light controls. Its bounds follow the
main window, with at least 32 pt of space on each edge. Closing restores the previous page.
The bundled translation renderer uses an aligned, borderless nonactivating panel so its native
service editors and original preferences remain intact without switching away from the host.
Records and vocabulary preserve their existing navigation/session state and prioritize content.

The lower-left Translation action invokes Easydict's original input-translation action while the
three central navigation destinations stay in place. It respects Easydict's configured window
type (the original fixed floating panel by default), size, appearance, pinning and dismissal.
Selection, OCR, dictionaries and service controls retain their complete native behavior.
The Translation menu exposes advanced actions and the unified Text Translation settings destination. A finished result
can open the existing vocabulary editor with source and translation prefilled; saving remains explicit.

## Visual language

The application logo uses two counterbalanced silver/ice light currents around a shared star
nucleus. A dark rounded-square app icon and flat 18 pt menu-bar templates share closed vector
geometry. The idle template has a small round nucleus; active sessions use a four-point core.
The separate in-app LiveLearn particle wordmark remains the readable header brand.
The refined mark has slender, continuously tapered curves without cut ends, a smaller nucleus,
more negative space, cooler silver color and restrained glow on a clean dark plate.

One system font family on one type scale, continuous window ground, one action accent.
Actions come in the three tiers of One Star Chart (stellar capsule, text action, glyph); the app's
own surfaces have no bordered or filled buttons. Selection is never a fill; only input wells may
carry a restrained fill, and large structural areas do not use different color bands.
The revised dark palette uses near-neutral space black (#030405), graphite surfaces (#101114),
silver-white accents (#DFE8F7), neutral text and fine material edges. The earlier navy
ground and large blue gradient were rejected by the user. Empty Home has a static field of
sharp white stars at three brightness levels and uneven drifting dust clouds; the center remains
dark for operation. Other pages use a much quieter field. Background light must come from
individual stars, never from lifting the black level across a whole window. Light mode keeps
the existing wilderness palette and list presentation. Source and language controls have
separate hover feedback. Main navigation is text with no enclosing surface or border.

## Living session action

The user subsequently rejected the gray membrane and requested a replacement. The current
center is a volumetric stardust core: 6,400 fine grains form folded three-dimensional currents,
with pearl highlights, quiet ice-colored depth and localized glow. The dark interior has dust
at several depths; there is no membrane surface, uniform point grid or outlined hoop. Its
center remains fixed while internal currents turn, breathe and respond locally to the pointer.
It renders at 210–360 pt and stays mounted above the controls through idle, running and paused
states; `HomeComposition` sizes its stage (360 pt at 1180 × 760, 233.7 pt at 960 × 600).
The superseded membrane remains available only to the historical preview renderer.
Round 12 refined the core's material, not its form: three grain magnitudes (fine 50 %, medium
40 %, bright 10 %), a feathered shell instead of a hard circle, the grey central lift reduced to a
faint ice-tinted depth, and a faint floor that rises toward the projected centre so the body does
not read as a hollow shell. The moods are told apart in a still: running brightens the pearl
highlights (×1.30), paused keeps idle's highlights (×1.08) over a slightly dimmer silver body
(0.94). Grain count, positions, motion and pulse are unchanged; Canvas and Metal read the same
palette and opacities.
After starting, the core has a clearly visible pulse (about 1.8 seconds per cycle, up to
7.9% radial expansion/contraction) and faster continuous rotation. Activation adds a brief
light/scale impulse. Speed is integrated with a smoothed activity value, so pause/resume never
jumps the orientation; paused/idle retain quieter movement. Reduce Motion stays stationary.
Start/Pause/Continue and Stop are independent 48 pt-high hit areas in a transparent group.
The primary action has an almost clear capsule, a quiet breathing light and a visibly moving
nebula around its edge. Stop is an unfilled text action with quieter stars. Labels remain steady;
busy states have a rotating arc and faster cloud motion, while Reduce Motion freezes both.
Keyboard focus has a visible outline. The existing page/window/app clock gates apply.
The capsule has one width, 184 pt, for every state, and is locked to the core's axis at one y
(core centre + 0.33 × stage + 44 pt) from idle through stopping; mode changes never move the core
or the capsule, and extra rows grow downward. 停止 hangs to its right as a satellite (80 pt,
12 pt apart) with the same width reserved on the left; there is no divider tick. The label is
15/500 `ink`. Dark: body `ink` 3 %, a 0.75 pt rim lit from the top arc, 20 → 8 → 5 %. Paper: a
clear body and a rim of 22 → 8 → 3 % that dissolves into the paper toward the bottom, with no
breathing glow (the paper particle rule below). Increase Contrast: an even 1 pt `ink` rim at 45 %.
The caption switch is a compact CC/text toggle with explicit on/off accessibility semantics,
still bound to overlayVisible and its existing close policy. It has no outlined box and no blue
dot: a CC glyph (12/500 caps, tracking 0.6, centred on the ideographs' box) 4 pt before 字幕, the
star point stamped under 字幕 when on. Listen/Converse/Face-to-face sit on the dock's geometry
(three 64 pt cells, 24 pt apart, 264 × 44) and wear the dock's own orbit — the same 192-grain,
four-stream recipe, flights and Reduce Motion — drawn at 0.8 of the dock's strength (full under
Increase Contrast), so the modes are a step quieter than the navigation. Their labels are 13/500
and keep their weight when selected.

Press feedback scales to 0.97 over 100 ms and settles over 250 ms. A single 650 ms ripple
acknowledges the action, and the dust core briefly gathers light and expands. The primary label follows actual preparation, connection and
finishing states, and transitional states disable the action. A short click latch survives
state changes so a double click cannot immediately reverse pause/resume.

Configuration reads as one centred sentence per route — `Safari ⌄ · 英语 → 中文 ⌄` — no wider than
the mode row (264 pt): values 14/400 `ink2`, the arrow and the 7.5 pt chevrons `ink3`, lifting to
`ink` / `ink2` on hover, press or an open popover, with no hover block in either theme. Source and
direction remain separate buttons with their own labels, help and popovers. Two routes (converse)
hinge on one column of middle dots: sources right-aligned before it, directions left-aligned after
it, 30 pt lines 4 pt apart. The hinge sits on the axis when each side fits its half and otherwise
slides the least it must; the direction truncates before a source falls below 72 pt. One route
renders exactly as the centred sentence. A running session replaces the mode row with one centred
status line, `正在翻译 · 0:46` (13/400, monospaced clock), 28 pt, then the caption toggle; the clock
is a leaf view, so its 1 Hz tick re-evaluates only its text. When the status dot and a single
route's dot are within 24 pt, the status line stands on the route's hinge, so pause and resume do
not move it; two routes keep a clear offset.

A failed session keeps the capsule on its slot as the retry (label 开始翻译, ⌘↩, and the VoiceOver
hint 会话失败：<title>). The recovery is a compact banner under the routes, where a start blocker
sits: title 13/500 `brick` · its action as an `ink` word on one line no taller than its text, then
the whole detail 11/400 `ink2`, at most 360 pt wide, selectable and never clamped, because raw
engine and capture errors reach it. The banner comes before the cloud cost note. At 960 × 600 with
converse routes and a cloud engine, the 104 pt of growth air under the unit holds the second route,
the whole banner with a one-line detail, and the cost note after it (the user's choice on
2026-09-28: it shrinks the minimum core from 272.7 to 233.7 pt and, at that size, lifts the idle
unit above the band's centre; the default window keeps its 360 pt core and its centring). A detail
longer than one line pushes the note, never the failure, below the fold. This departs from
"recovery primary, retry secondary" (Copy and help): with the capsule kept, retry is the loudest
control and the recovery is the only brick line on the page (signed off by the user on 2026-09-28).

Paper particle rule (wilds theme): no halo sprites, no radial fills, no grey disc — crisp dots,
with depth by size and alpha and the forest accent only on the lit current. The core's tones are
current accent, front `ink` and far `ink` with a tone gain of (1.2, 1.3, 1.0), which keeps its
focal mass; the paused paper core keeps a faded forest current (its silver is the accent halfway to
`ink2`), never soot. The wordmark on paper is engraved: `ink` at 0.82–0.98, composited grain by
grain as the sprites are. Orbits and the capsule drop their halos and glow. Increase Contrast lifts
Home's quiet inks one step (values `ink2` a third of the way to `ink`, quiet text to `ink2`,
resting dock and mode labels to the value ink) without flattening the hierarchy.

Dark Home takes material cues from the local TerseAI study: thin reflective edges and a layered
5,200-grain field in the same pearl and pale ice tones as the core. One third is dispersed across
the entire field so the top, sides and bottom retain visible stardust. Unequal random clumps, sparse
gaps and independent local drift replace the two regular crossing bands. The central body has
uneven volume depths and multiple overlapping density waves. The core and working controls
have feathered particle density; the dust's core fade (radius 0.33 of the stage) and control fade
(the capsule's top to the dock, ± 220 pt), the stars' quiet box and the pointer's protected zone
all come from `HomeComposition`, so they move with the unit at every window size. Glint-magnitude
stars and bright dust keep off text and controls: their clearance is 0 within 12 pt of the header,
the dock and the control column (± 184 pt from the capsule's top down) and 1 beyond 28 pt, eased
between, so no false badge star sits under 词汇 or beside the configuration. Off Home, the sparse
sky keeps the same 28 pt off the records rail while it is open, and off the vocabulary rail and its
top line (`SkyKeepOut`). Running/paused retain a quieter field. The black
ground stays unchanged. The native orb and local particles use page/window/app-aware clocks;
open ambient windows continue at 12 Hz when the app loses focus (30 Hz in the foreground).
Occlusion alone no longer freezes these ambient effects; closed/minimized windows, hidden
pages and Reduce Motion still stop them. Vocabulary camera rotation retains its separate gates.
Both bright stars and fine dust move on independent curved trajectories on Home; the bright
stars are no longer a static Canvas. Motion is large enough to be visible over two seconds,
with different speeds and shimmer, rather than translating the whole star field.
The user's shape request refers to star arrangements: loose asymmetric spiral arms, open arcs
and constellation-like clusters, with random scattered dust around them. Individual stars
remain fine points and modest glints; large four-/six-point icons were not the requested change.
Reduce Motion removes continuous/spatial motion while preserving text and static geometry.
The native particle clock must resynchronize a replacement display link even when its logical
playing flag is unchanged. Reparenting a live layer or returning to the foreground must not
leave it paused. Background 12 Hz motion advances at the same speed as foreground motion;
long suspension gaps remain capped to avoid a catch-up jump.
CanvasUI-inspired pointer feedback locally displaces the background particles and gently pulls
the central form; clicks emit bounded ripples. An app-local, pass-through input surface never
consumes events, excludes window chrome and the main controls, and throttles motion input.
The interaction decays on exit, stops off-page/at reduced motion, and never issues session commands.
The active status strip gives all remaining width to its wave grid, with trailing facts/actions
protected by their layout priority. No fixed 520 pt cap or elastic spacer may strand empty width.

Main navigation is bare text: no capsule, background, hover block or selected underline.
Bottom-rail controls are unboxed. The three navigation destinations brighten on hover, compress
to 0.92 with a 1 pt depression over 70 ms, then settle with a short spring. Translation and
Settings have no standing fill, gradient or border. Hover introduces only a feathered local
light and brighter ink: the gear turns 18 degrees, and the translation glyph lifts 1.5 pt;
the glyphs grow by 8% while the text and hit area stay fixed. Press contracts the control to
0.95, concentrates the light and releases with a short spring. Their original hit areas remain.
Reduce Motion removes scale and displacement but keeps immediate contrast feedback; disabled
controls and keyboard focus remain explicit.
The empty and no-match states of the dark star map (添加词汇 · 导入文件, 清除搜索) use the same strong
text actions as the list's empty and no-result states, centred on the sky with no glyph. Neither
adding a word nor clearing a search introduces a standing gray button surface.
The selected label is wrapped in a thin, soft band of 192 silver dust grains. Four interleaved
streams have irregular radial depth and small feathered halos; there are no cross-shaped stars,
dominant glints, drawn outlines or solid fills. Each stream preserves its angular slots with
bounded local drift, so its density cannot collapse after minutes of motion. Light is balanced
around the word, and the text keeps a clear interior. Initial appearance starts in place.
Selection changes launch immediately along independent, softer damped arcs, settling within
400 ms. Rapid retargeting preserves position and velocity. The small field requests 60 Hz
during its 480 ms flight window and returns to 30 Hz for soft drift, with the usual 12 Hz
background cap. Motion time determines the rate so a paused flight resumes smoothly.
Grains dim continuously near text. Selection still has brighter text and native
accessibility state; decorative stars never take clicks. The small field shares the visibility
clock gates, and Reduce Motion displays the selected cluster immediately without movement.

## Configuration and records

Dictation uses a dark 56 pt capsule with 28 pt corners, a subdued HUD material and fine outline.
Five white bars use real capture RMS with a 0.4 attack / 0.15 release envelope and bounded
per-packet variation; silence stays still. Text expands the capsule horizontally, with explicit
pending, correction, completion and error states. The panel enters with a 350 ms spring, resizes
over 250 ms and exits over 220 ms. Reduce Motion keeps state changes without spatial animation.
It never becomes key/main, and decorative backgrounds never receive input. Prefer a clamped
position beside the captured input range; the user can choose screen-bottom placement.

Idle and active source popovers use one form on a compact 480 pt surface (padding 24) with sparse
starlight, unboxed channel groups, softly fading rules and two-column PaperMenu fields. The title
is 17/500. Channels have no SF icons: a bare name, 15/500 `ink` when on and `ink3` when off, with its
switch on the rag and its fields 16 pt below. Field labels are 11 `ink3`; values are 15/400 `ink2`
lifting to `ink` on hover or open, with the direction arrow in `ink3`. A value the draft changed is
written in `ink` with a star point 10 pt left of its text; a channel name takes the star only when
the draft turns the channel on. The sky is bare points without glint rays — five in the 480 pt
shell, three in a narrower one — each at least 16 pt clear of the title and of the ✕'s target. A
quiet footer puts the engine link, 检查音源 and ⓘ on one baseline. The language-only popover shares
the same surface and close action at a fixed 320 pt. ✕ is a glyph action and 取消 a text word. The
dark body stays near-black (`presentationBackground(ground)`); light mode retains the wilderness
palette. Active changes stay in a local draft until explicit apply; inventory refresh must not
reconcile live selections. Active apply is the compact capsule, on one row with the restart note
(broken at the comma), and cancellation discards edits.

PaperMenu sheets are the floating material, and the shadow comes from the sheet's shape only (the
per-glyph halos were a bug). Rows rest in `ink2` and turn `ink` when chosen or highlighted; the
highlight is `fill`, a step stronger (`fillHover`) on the chosen row. A chosen single-choice row
carries the star point and an unchosen one leaves its slot empty. A check row is an empty 6 pt ring
(1 pt `ink3`, `ink2` under Increase Contrast) while unticked and the lit star centred where the
ring was once ticked. Everything sits on one 26 pt grid, so paired columns (源语言 | 目标语言) share
baselines; column headers (11/500 `ink2`) differ from sub-sections (11/400 `ink3`), and the column
rule runs the sheet's full height with both ends faded. A PaperMenu may be labelled by a bare glyph
instead of its title (the vocabulary rail's ···). The menu-bar panel's status is a label (11/500
`ink2`, clock 11 mono `ink3`) led by a `NowMark` — full while audio is live, 45 % while connecting
or waiting, hidden when paused or idle — instead of a breathing dot; its group rules are inset to
the 16 pt text column and fade at their trailing end; rows and order are unchanged. The source-check
window sits on the ground with a 17/500 title; its outcome is 15/500 (`brick` when failed), the
remedy comes directly under it as a strong text action (with a ↗ when it leaves the window), the
details box is only as tall as its lines up to 100 pt, and 重新检查 / 关闭 are text words.

Settings use a shared 1080 × 740 content layout and retain all original shortcuts. The 2026-09-14
redesign ("Observatory Rail", doc/design/2026-09-14-settings-observatory-rail.md) makes the modal
the same world as Home: navigation is bare text without icons, fills or underlines, grouped
without reordering; the selected page is marked by seven small stars in the empty gutter left of
its label, which fly on independent curved paths to the next row when the page changes (every
point has landed within 0.50 s; the rail runs at 30 Hz for 0.7 s after a change and 15 Hz at
rest, one shared policy for both processes) and drift locally at rest (stationary under Reduce
Motion and in offscreen renders). The sidebar carries only the plain-text brand and the group
labels — there is no "Settings" caption, which read as a fifth group; the first group label
shares the page title's baseline, so the sidebar and the page start on one line in both
processes. The particle wordmark stays on Home. The page title is the display size with no
symbol badge; groups are separated by whitespace and 11 pt labels, rows by 0.5 pt rules that
fade at their trailing end; host-owned settings have no graphite sheets, glass or card strokes
(the `LuminousGlass` modifier no longer exists). The ink ladder of a page: row names `ink`/400,
menu values `ink` with an `ink3` chevron, actions (bare words, `SettingsActionStyle`) `ink`/500 and
answering the pointer with the neutral interaction light even when the word is `brick`, facts
`ink2`/400, notes and not-yet-known states (未检查, 正在检查, 不可用) `ink3`/400; a state beside an
action (可下载 · 626 MB, 已安装 · 626 MB) steps down to `ink3` 24 pt before it so the action leads. A
section's help is a bare 11/400 "?" at the rag of its label's line, never right after the label;
row help is merged into the group's. A note about one row is that row's; a group's note hangs 16 pt
under its last row, 36 above the next label; a credential row draws its status line only when there
is one. Under Increase Contrast the dark switch track and the dark text wells get an edge back.
Easydict's embedded pages share these visual
rules through settings-only presentation adapters, preserving their configuration bindings.
Settings controls brighten over a feathered local light on hover. Sidebar rows, sub-tabs,
menus and actions compress to 0.96 with a 1 pt depression over 70 ms, then settle with a short
260 ms spring. Sub-tabs retain clear, padded hit areas; hover does not move their layout.
Reduce Motion keeps contrast feedback without displacement. This shared treatment applies to
all settings pages and preserves their existing selection and action bindings.
Text translation is native content inside the same main-window modal. The original Easydict
settings views load from a bundled component into the content column; the host owns the one
sidebar, background, close action and window. There is no separate settings panel, duplicated
sidebar, cross-process frame synchronization or window-order repair. Screenshot focus changes
do not dismiss settings. The query helper keeps the original translation windows and runtime;
both components share its established preferences domain, never the host's defaults.
Segment, pane, preset and theme
selection share one stamped star point drawn with the rail's bright-star recipe at small scale
(a 1.4 pt core, two short rays, a 4 pt halo; plain ink under Increase Contrast; on paper a crisp
3.2 pt point with rays at ± 3.4 pt and no halo — the one recipe the host `StarMark` wraps), at a
fixed offset from its word: below the word in a row of words (host segments and panes, 界面大小,
and a preset's caption — the three preset specimens hang from one baseline, so their captions share
one too), beside it where a large title follows (theme titles). Small switches (30 × 18) show their
state in the track, with no ring: on is an `accent` 18 % track under an `accent` knob; dark off is
a `fill` track under an `ink3` knob; paper off is an `ink` 12 % track under a paper knob with a
0.75 pt `ink3` edge. Under Increase Contrast the on track rises (45 % dark, 30 % paper) and the dark
off track takes a 1 pt `ink2` edge. This is a global control change, so the source-row previews
changed with it. Host menus use PaperMenu's
bare text and small chevron. Translation configuration uses the same closed-menu grammar and
switches around Easydict's original values and actions. The modal background is a static, sparse star field
thinned under the text column — the rail is the only live canvas in Settings, and the Home page
underneath holds still while it is blurred. The modal fades and rises in over 240 ms and fades
out over 160 ms; the blur never animates; the card has a 14 pt radius and a 1 pt edge of the
floating material (top-lit in the dark); the dark card casts no shadow and the light card a
soft one drawn behind it, so the card's view identity never depends on the theme. Theme choice
is two frozen scene previews whose image edges are the one permitted hairline in Settings, of
equal weight on both pictures; the selected one carries the star point and its name in `ink`,
and its status word (使用中 `ink2`, 选择 `ink3`) is never blue. Step numerals (网页翻译) are 13 mono
`ink3`. Every page's text column, caption appearance included, sits on the same 576 pt measure,
centred in the page pane (`LiveLearnSettingsPage.contentGutter`: never under the ✕'s 48 pt corner
column, never closer than 24 pt to the rail; the ✕ — a 13 pt glyph action in `ink3` — sits on the
rail's brand line). Caption appearance keeps every line on that column, the stage's scene words,
播放 and facts line included; only the stage's picture breaks out of it, to 24 pt from the pane's
left edge and as far on the right (none at all on cards under 836 pt, where it would be a few
points), on a neutral #0D0E10 backdrop (never navy), with the caption block anchored 20 pt from the
edge the overlay sits on and without the overlay's always-empty incoming slot, above that
scrolling inspector. Presets sit in three equal columns under a 预设 eyebrow. In the host's own
settings pages a row's control sits at the trailing rag, centred on the name's 16 pt line and
counting only that line in layout (every one-line row is 40 pt, whatever its control; a settings
action's and a shortcut binding's 28 pt target overhangs into the row's padding), and the one
exception is decided by the control rather than the row: a field the user types into, and a
field-plus-buttons group that writes lines back under itself, sit under the name at the measure's
left edge — an address filling the measure, a name, id or key 320 pt wide — so 模型 is a menu at
the rag under Whisper and a field under the name under a cloud engine. Within a group a rag control
that qualifies the form sits before it, never inside it; only a switch that belongs to the whole
engine may close the group after the form. Shortcut rows keep fixed trailing slots (binding 120,
mode 40, clear 32) so a bound row does not shift; the recorder has no fill in any state, and while
listening it shows a 2 × 14 pt now bar and 按键后松开. The bundled translation helper's service rows
still keep their fields at the rag; that page is not converted here. Home source/language rows
remain transparent in idle and active
sessions, without a shared fill, border or shadow; individual controls retain hover/press
feedback. Important notes and permission explanations remain readable.

The top-left LiveLearn wordmark is formed from fine particles sampled inside the actual
LiveLearn glyphs, with tiny local motion and starlight. It must remain a readable word, not
a standalone round nebula icon. Its help and accessible name remain LiveLearn. On paper it is
engraved (the paper particle rule).
The records directory toggle, 目录, lives after its fixed-width brand slot as a bare word with the
word-toggle look (`ink` with a stamped star while the directory is open, `ink3` while closed), no SF
icon and no hover plate; it stays a button with its label, value and ⌘⇧L. The window header's
error strip offers 重试 as a text word and ✕ as a glyph.
Collapse animates a clipped outer width while retaining the full sidebar subtree,
search and list state. Hidden controls are disabled and absent from accessibility navigation;
collapse releases keyboard focus so hidden search cannot keep accepting input.
The two existing theme palettes are selected in Settings. Background scenery defaults off;
when enabled, it is a small corner accent on idle Home, outside the controls. No scenery
renders during an active session or on content/settings pages.

Records (round 12) follow the Observatory grammar. The rail has two verticals only — an 8 pt slot
centred 12 pt in (the selection star, or the live row's 2 pt now bar) and the text column 24 pt
in. Its header is 记录 15/500 with a bare "+" glyph, 36 pt from the top; `BareSearchField` sits
under it and is hidden, with its query cleared, while there are no records. A row's title is the
record's first translated sentence (then its first recognised sentence, then its time), 13/400,
one line, `ink2` at rest and `ink` when selected, hovered or live; under it one 11 `ink3` fact line
in monospaced digits, `17:05 · 6 句 · 6:12 · Safari`. A row speaks a status word only when something
went wrong (未正常结束); unsaved records are counted once on the day label (N 条未保存). Selection is
the stamped star plus `ink` title and an `ink2` fact line, with no fill; hover changes the title's
colour instantly. The rail's divider fades at both ends and stops above the dock.

The reading page is one block — the 72 pt timestamp gutter plus the 640 pt measure — centred in
the content width with at least 32 pt either side, whether the directory is open or closed.
A record opens on a masthead that scrolls with it: a 24/400 date line on the rail header's
baseline, then an 11 `ink3` fact line (sentences, length, sources, direction, gaps). The live
page's masthead is 当前会话 over the session's own day, start time and sentence count; it dissolves
as one unit over its first 16 pt of movement, so it is whole at rest and never sliced by the
32 pt top fade. The empty page is left-aligned in the masthead's slot: a 24/400 opening line, one
13/400 `ink2` sentence and the strong word 前往首页 — no icon, no slab, nothing in the rail. A failed
session with nothing recognised opens on a recovery masthead instead: the advice title 24/400 on
the same top line, 已停止 · 没有识别到内容 in 11/500 `brick`, the selectable detail in 13 `ink2`, and
the action as the page's one 15/500 `ink` word. Translations are set in `readingInk` (#E6E9EE on
true black, where a near-white CJK stroke halates; `ink` on paper and under Increase Contrast).
An open sentence's reserved slot says only what is true (识别中, 翻译中, 已暂停); a sentence left open
in a finished record is set as a settled one. The partial source reaches at least 4.5:1 (68 % in
the dark, 90 % on paper). A static time thread runs down the now-bar slot: a 1.6 pt `ink3` point on
each finalised sentence's first line joined by a 0.5 pt hairline (20 % dark, 22 % paper); it breaks
at a gap, runs into the now bar or the listening dot as its bright head, and is hidden from
VoiceOver. A gap is its label on the text column with a trailing-fade rule and 24 pt of air. The
transcript's edges dissolve (32 pt at the top, 24 pt at the bottom, alpha rising as t²) and the
live line rests 36 pt above the horizon. 回到实时 is a text word over a feathered ground halo.

The transport is a horizon, not a card: no fill, stroke or radius, one rule fading at both ends,
and a 48 pt row on the ground above the dock, spanning the reading block (on the vocabulary page,
the content column under the search). The transport marks sit in the timestamp gutter with their
right edges on the timestamps' edge; the lane label starts on the text column at its natural
width, and the sound line takes all the remaining width, its ends fading over 16 pt. Then come
保存 / 导出 and 字幕 / 锁定 as two groups, the facts in 11 mono `ink3` and the status sentence in 13
`ink2`, which hugs its words up to 320 pt and wraps to a second line rather than being cut. Status is
always words, never pulsing symbols; while the sound lines name every heard lane the sentence says
only 正在听. Beside a record read back the horizon repeats nothing the masthead says — no title and
no duration — and the start ▶ turns into a quieter 10 × 12 pt mark (`ink3` beside a record, `ink2`
beside a just-finished session) with the word 新会话 on the text column, which is skipped by Tab and
VoiceOver because the ▶ already carries 开始 and ⌘↩. A failure whose note repeats the status says
only 已停止 on the horizon, and the wave stays a still wave.

## Ambient motion and performance contract (2026-09-14)

The living sky is a design commitment and a cost; this contract keeps both. Every continuous
motion runs on a gated clock: 30 Hz while the app is active, 12 Hz in the background, paused
while the window is miniaturized or hidden, while a settings modal covers and blurs it
(`ambientMotionPaused`), and whenever nothing can be seen — a locked session, sleeping
displays, a switched-out user (`AmbientPower`). Occlusion by other windows alone does not pause
it. Time never jumps on resume. Everything on Home that moves continuously — the star field,
the dust, the stardust core, the particle wordmark, the navigation and mode orbits (since
round 12 the mode row reuses the navigation's field; its three nebula-halo layers are gone) and
the action button's breathing light — draws as GPU point sprites in Metal
layers driven by display links, so an idle Home evaluates no SwiftUI body and re-renders no
`Canvas` periodically; the SwiftUI `Canvas` code remains the reference and the only path for
offscreen previews, frozen frames, Reduce Motion and machines without a GPU, and a sprite layer
is accepted only when its offscreen parity against that Canvas is invisible at 4× (mean below
one level; at the 2× scale the product renders, p95 ≤ 1 for every pair). Grains narrower than
1.3 pt are boxes, halos are pre-rendered soft sprites, and the particle mathematics lives in the
optimised `ParticleMath` module. Frame rates of remaining SwiftUI clocks are divisors of the
scene's 30 Hz so they never add render passes. Settings keeps exactly one live canvas. Hidden
pages are unmounted until they hold state worth keeping. Round 12 added no clock and no live
canvas: its marks (star points, the compact capsule's grains, popover skies, vocabulary type
glyphs, the time thread) are static, the horizon's wave fades its ends with a gradient stroke
rather than a mask, and the menu bar's breathing dot became a still now bar. The 184 pt capsule's
glow sprite needs 429 px at 2×, under the 511 px point-size limit; the 4× parity run still stops
at that limit on the start light (680 px), as it did before the round.

Two bounded deviations of the sprite layers from the Canvas reference are recorded rather than
fixed. (1) Same-bin compositing: a Canvas alpha bin is one path filled once, so its grains
combine by nonzero-winding union — coverages add where two grains merely share a pixel and do
not add where they overlap — while the Metal path composites one source-over sprite per grain,
which falls short of the sum in the first case and exceeds the union in the second. Over the
wordmark's 0.58 pt lattice the first case dominates: Metal deposits 94.3 % of the Canvas ink at
1× and 97.1 % at 2× (a coverage effect, identical in both themes), with a handful of brighter
pixels where grains overlap; per pixel, 1× mean 0.72 / p95 6, 2× mean 0.48 / p95 1. An ablation
at one eighth of the grain density leaves one pixel of −6 levels in the whole wordmark, so the
box sprite's coverage against CoreGraphics' antialiasing is exact and the union is the entire
cause. The additive mask pass is not a correct fix (it equals the union only for adjacent grains
and overshoots for overlapping ones). (2) Ray crossing: a bright navigation star's two rays are
one stroked path on Canvas and two boxes on Metal, so their 0.5 × 0.5 pt crossing double-blends
— about 7 levels on one pixel, under the disc that covers it.

## Vocabulary star map

Dark vocabulary opens in Star Map; the content's top line carries `BareSearchField` and the words
星图  列表 with the stamped star under the chosen one (the wilds theme stays a list and has no
switch). Search, section filters, import, edit, undo and export retain their existing data paths.
A term is an interactive star whose hue lives only in its point: ice (`starBlue`) for hot words,
gold (`ochre`) for fixed translations. Shape encodes type as well as colour: a fixed translation is
a binary star — two close points under one halo, the companion 0.75 of the core, 3.6 pt apart,
turning with the field. The same glyph (`VocabularyKindMark`) marks the rail legend, the list
gutter and the import preview. Positions are deterministic per ID; a term's size and brightness
grade with depth only and do not claim frequency, mastery, importance or semantic relationships.
There is no radial haze; the ground stays #030405 and the canvas draws only points and 0.6 pt
lines. The dust is a loose two-arm spiral around a grain nucleus in neutral silver, fitted to the
sky above the chrome row with equal margins; the nucleus stays the densest dust but never outshines
the dimmest term (nucleus peak 144 against term cores from 163). Orbits fade with depth; the dashed
outer orbit and the "+" glints are gone. Halos thin as a page fills (√(32 / n)), so a 120-star page
is not a blue wash; the gold halo is champagne, not brown. No invented vocabulary fills an empty
library. Empty and unmatched states expose an immediate add or clear-search action.

Dragging rotates the projected 3D field; pinch and explicit controls zoom. Names have no chips: 12/400
`ink2` (the back half `ink3`, all `ink2` under Increase Contrast) with a ground-coloured text halo;
a hovered or focused name grows in place to 13/500 `ink`. A name sits beside its star, keeps clear
of every other star — a binary's companion included — by 16 pt beside and 12 pt above or below,
avoids the nucleus and the selected point, and keeps last frame's side while it can. Up to 26 terms
on a page every star is named; above that names spread over a 4 × 3 grid of the sky and are capped
by its area (18 at the minimum window, 26 from the default), and an unnamed star names itself on
hover, focus and in the list. Selection is a bare annotation beside the star instead of a card:
the source 15/500 `ink`, the detail 13/400 `ink2` (`brick` when a legacy translation needs repair),
编辑 and a ✕ glyph, at most 240 pt wide, other names avoiding it. The bottom chrome floats on the sky
with no rule: count and paging 11 mono `ink3` at the lower left, camera glyphs 11 pt `ink3` at the
lower right (reset is dot.viewfinder, 复位星图), and the gesture hint only while the pointer is over
the map. During a session the chrome yields to the horizon: the glyphs appear on hover or keyboard
focus, the count only while searching, and VoiceOver keeps the camera actions on the map. The map
pages in groups of 120; paging remains visible, and search/list access the complete library.
New or edited selection reveals its page.

The vocabulary rail is the records rail's geometry (slot, text column, rag and header baseline),
so switching 记录 ↔ 词汇 does not move a glyph: 184 pt wide, header 词汇 15/500 with a bare "+" (⌘N)
and a ··· glyph PaperMenu (导入词汇…, 导出词库备份, 置顶窗口 in the standalone window, 词汇生效说明);
rows 13/400 `ink2` → `ink`, no icons, no fill. The slot holds only the chosen section's star, in its
class hue. The rail doubles as the legend: 热词 and 术语 carry their unlit class glyph, at the list gutter's
strength, before their 11 mono `ink3` counts, and the floating legend is gone (at 60 % the glyph
all but vanished at 1×, and the rail is the only place the two kinds of star are taught). A ground patch keeps sky grains off the
rail's words. The list has no header row and no em-dash or type column: the type glyph in a 22 pt
gutter, the word 13/500 `ink2` turning `ink` when selected or in hand, and one translation column
for the whole list (the widest pair + 24 pt, 160 pt to 45 % of the row) on the 576 pt measure; the
selected translation lifts from `ink3` to `ink2`; pencil and trash glyphs appear only for the row
in hand, and the row keeps 选择 / 编辑 / 移除 as VoiceOver actions and speaks its type. Rules fade and
the last rows fade out before the dock. The list's empty and no-result states are a 24/400 opening
line, one sentence and strong text actions (添加词汇 · 导入文件, or 清除搜索). The import and editor
sheets have 17/500 titles, wells with no bright outline in the dark (a hairline again under
Increase Contrast), 取消 as a text word and the compact capsule as the commit (⌘↩). Packs are a
15/500 title with a sample line and 预览 N 条 as a text action; corrections put timestamps in the
72 pt gutter and mark candidate spans with an `ochre` dotted underline. Invalid legacy translations
remain marked for repair.

Ambient motion is bounded to 30 updates per second and pauses off-page, in hidden/minimized
windows, when the application is inactive, when hovering or focusing a star, during selection
or editing, and under Reduce Motion. Keyboard-accessible camera controls accompany gestures.
Stars are native buttons with descriptive accessible labels; focus order is stable across rotation.
This data visualization is separate from the optional Home background-scene setting.

Shiyun's screenshots and README were studied as reference only. No upstream code, assets,
poetry or metadata are bundled. Particle generation, projection and interactions are original Swift.

## Copy and help

Remove repetition before reducing essential reading size.
Static background information uses opt-in help popovers (in Settings, a bare "?" at the rag of a
group's label line). Existing note fields remain visible
by default because they can contain errors, permission consequences, costs and credential state.
Cloud processing/cost consequences remain visible on Home, including the minimum window with
converse routes, a cloud engine and a failure or blocker; only a failure detail longer than one line
pushes the note below the fold there (see Living session action). Failure states put the recovery
in `brick` with its action first and the whole detail readable; on Home the capsule stays as the
retry and is the louder control (a round-12 lead decision, signed off by the user on 2026-09-28,
that replaces "retry secondary").
Never hide errors or reset user preferences to simplify appearance.

## Evidence process

The supplied article's Discover/Define/Deliver workflow informs the process, especially
fresh screenshot-only critique and removal of elements that do not add value.
Use bounded review rounds and actual app checks. Native offscreen previews use a simple
stand-in for controls ImageRenderer cannot render; runtime keeps the native control.

Current black-palette evidence: doc/design/2026-09-12-black-sky.md.
Earlier article analysis: doc/design/2026-09-08-minimal-interface.md.
Round 12 direction and evidence: tmp/round12/DIRECTION.md (binding direction), FIXES.md (fix-pass
decisions), baseline/, after/, after2/ and final/ renders, each with an INDEX.md; the record is
doc/项目实现文档.md §5.12.

## Shared interaction contract (2026-09-12)

Text actions and bare glyph actions share a 100 ms press and 200 ms release, with
a small scale response, local hover feedback, and native keyboard focus shapes. Native
menu rows stay immediate. Reduce Motion removes spatial press movement and freezes the
wave phase even when new audio levels arrive. Navigation and segmented labels keep stable
font weight so selection does not shift text. Small icon actions have at least a 28 pt
macOS hit area; existing 36–48 pt primary targets remain.

Settings fields own exactly one focus binding, including when the editor supplies it. Return
advances a term's source to its translation; Command-Return saves. Caption presets show the
selected star point and return to Custom as soon as their values change. Download and test
progress belongs to the app model so leaving a settings page does not hide an active task.

Records open from the beginning; only live transcripts follow the tail. Saved state comes
from the actual record. Permanent deletion requires a record-specific confirmation.
Errors remain visible even without a recovery action; empty and unmatched states offer a
concrete next action. Hidden pages and collapsed search fields release keyboard focus.

The caption toolbar remains visible while a keyboard/assistive focus or popover needs it.
Native focus bridges are omitted only for offscreen ImageRenderer fixtures. Translation
workbench opening is coalesced and reports progress/failure in place; every menu entry
synchronizes the requested theme. Non-applicable upstream service controls are hidden
from accessibility, and detected-language/model controls have descriptive labels.

## Unified text-translation settings (2026-09-12)

Text Translation lives in the shared settings sidebar. Its eight original pages retain their
service, language, shortcut, OCR and privacy bindings independently of live captions. The main
app and bundled translation process hand off one visible settings surface at the same position;
they do not copy API keys or overwrite each other's engine preferences.

The 2026-09-18 visual refinement supersedes the stock settings chrome restored on 2026-09-17.
The query floating window still belongs to Easydict. Its settings pages share the host's black
ground, 24/13/11 pt hierarchy, 576 pt reading measure, whitespace groups and fading rules.
Eight plain-text destinations use a single selected star point. The native TabView remains
underneath to preserve page identity and appearance lifecycle; only its tabs and border are
hidden. FormStyle adapters keep the original Section contents, footers and configuration
bindings. Menus preserve native Picker content/tags; editable service fields carry explicit
labels above their inputs, and shortcut recorders keep their original capture behavior.

Services retain native List selection, keyboard navigation and reorder, with no row fill: the
chosen service or window configuration is `ink` with one leading star point (drawn 5 pt in, so a
clipping row cannot cut its halo), others `ink2`, second-level lines `ink3`. Choice menus
(`TranslationChoiceMenu`) follow PaperMenu's grammar — the value in `ink`, a 7.5 pt chevron lifting
to `ink2`, the chosen row marked by a leading star slot instead of a trailing checkmark — and the
star and its slot scale with 界面大小. The helper's switch is the host's. Service names sit above
their access requirements,
leaving room for the enable control; add/remove, service selection and storage remain original.
MDict retains an explicit List for its reorder/delete gestures. Add-service and model-picker
sheets use the same restrained surfaces. History/favorites use a secondary text switch without
a second star marker. Both themes and reduced motion are supported by the scoped styles.

Service ordering, language, appearance, shortcuts and OCR preferences stay in the existing
helper domain without resets. Independent updates/login items remain owned by LiveLearn, and
upstream funded keys and telemetry remain excluded. Translation results keep Easydict's own
appearance rather than the host palette.
# First encounter (2026-10-03)

The first-run flow uses the existing stellar/wilds palette, with a quiet orbit of points on
the left and a readable 34 pt serif heading on the right. Three steps introduce realtime
translation, offer unchecked optional modules, and explain the first session. Every screen
can be skipped. Copy should feel welcoming without claiming that permissions, models or
services are ready. The visible subtitle illustration is labelled as an example.

The point field uses the shared visibility-aware motion clock. Reduce Motion freezes it and
removes page transitions. Sound is off by default; explicit opt-in plays a short synthesized
chime, stopped when the introduction disappears or the app loses focus. Settings gains a
Function Management destination before the optional-feature pages. All installation states
come from the same module store, and missing modules offer installation rather than errors
about an incomplete application bundle.
