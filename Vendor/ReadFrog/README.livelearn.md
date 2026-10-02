# LiveLearn local distribution of Read Frog

Upstream: https://github.com/mengxi-ream/read-frog
Commit: `54e32113858a4e9cc06c2e8430c4640415c776d0` (1.47.0).
Modified for LiveLearn on 2026-09-12. This extension remains GPL-3.0; see LICENSE.
It is bundled as a separate browser program, not linked into the Swift application.

## Changes

- Local installation and onboarding, LiveLearn name/icon, independent stable extension ID.
- Keeps upstream DOM traversal, bilingual insertion/restoration, SPA/iframe handling,
  selection, input translation, provider configuration, queues and caches.
- No install probe, hosted account UI, hosted provider choices, cloud sync UI,
  blog promotion, telemetry, uninstall survey or official-site settings bridge.
- Microsoft default, opt-in automatic translation, optional Ollama and user providers.
- User-initiated selection handoff uses the public livelearn://translate?text= URL scheme.
- UI assets are bundled locally; translation still uses the selected service.

## Build

Use Node/pnpm compatible with package.json:

```sh
pnpm install --frozen-lockfile
WXT_SKIP_ENV_VALIDATION=true pnpm build
SKIP_FREE_API=true pnpm exec vitest run src/utils/__tests__/livelearn.test.ts
```

The workspace script/build_browser_extension.sh packages the compiled files, this full
modified source tree, dependency license inventory and checksums. Dependencies, output,
environment files and credentials are excluded. No signing private key is required;
the public manifest key only fixes the extension ID. Preserve it on updates.

The app prepares bundled files under Application Support and opens the selected Chromium
browser's manager. Browser loading and permission remain user actions. Keep the folder
in place and reload after updates. Settings persist in browser local storage.
Safari is not supported here. Firefox requires its own signed package.

KISS Translator (https://github.com/fishjar/kiss-translator) informed concise bilingual
reading interactions; no KISS code or assets are included.

