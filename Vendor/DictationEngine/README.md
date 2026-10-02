# LiveLearn dictation runtime

This Swift package is the optional process runtime for LiveLearn's advanced dictation
adapter. It contains the existing Swift protocol, audio and transport implementation,
now separated from local research documents so the public project can build it.

Build with `zsh script/build_dictation.sh` from the repository root. Xcode with a
macOS 26 SDK, `pkg-config` and `opus` are required. The normal LiveLearn core build
does not run this step. The module also includes the separately built Chatterfly bridge.

No original third-party input-method application, account token, extracted service key,
or fixed device identity is distributed. Supply your own authorized service configuration.
Protocol support does not grant access to a provider's service. Apple Speech, Whisper and
the other shared LiveLearn recognizers remain available after enabling dictation.

License: GPL-3.0; Opus keeps its BSD-style license. The implementation was derived from
the local Swift rewrite; research archives and third-party installers are not included.
