# Third-party software and materials

LiveLearn's own code is distributed under GPL-3.0. The components below retain their
original notices and licenses. GPL permits commercial use; it does not provide access
to a third party's hosted service, paid account, trademarks, or API credentials.

| Component | Version / origin | License | Source and notice |
| --- | --- | --- | --- |
| Easydict, optional text translation | `1d2dde404836fd6d0b914c23d8e44ff7eba13d7c` | GPL-3.0 | `Vendor/Easydict/SOURCE.json`, `LICENSE`, sanitized source archive and `Integration/` |
| Read Frog, optional browser extension | `54e32113858a4e9cc06c2e8430c4640415c776d0` | GPL-3.0 | `Vendor/ReadFrog/`; dependency inventory in `public/DEPENDENCIES.json` and `public/THIRD-PARTY-NOTICES.txt` |
| ThinkingOrbsKit | thinking-orbs 0.3.1, native Swift port | MIT | `Vendor/ThinkingOrbsKit/LICENSE` and `README.livelearn.md` |
| WhisperKit / argmax-oss-swift | 1.1.0 | MIT | [Argmax](https://github.com/argmaxinc/argmax-oss-swift/tree/1.1.0) |
| swift-argument-parser | 1.8.2, resolved dependency | Apache-2.0 | [Apple](https://github.com/apple/swift-argument-parser/tree/1.8.2) |
| ZIPFoundation | 0.9.20 | MIT | [ZIPFoundation](https://github.com/weichsel/ZIPFoundation/tree/0.9.20) |
| Opus, optional dictation runtime | linked at module build time | BSD-style | `Opus-LICENSE.txt` in the module, [Opus](https://opus-codec.org/license/) |
| Solar System Scope planet textures | INOVE | CC BY 4.0 | `Sources/LiveLearnApp/Resources/Worlds/ATTRIBUTION.md` |
| Kenney Nature and Castle models | Nature Kit 2.1 / Castle Kit | CC0 | `Sources/LiveLearnApp/Resources/Worlds/Nature/LICENSE*.txt` |

Easydict's archive includes the notices for its CocoaPods and other dependencies.
The text module includes the corresponding sanitized upstream archive, integration
overlays and preparation scripts. The browser module includes its source archive.
The dictation modules' Swift source and build scripts are in this repository.

Whisper models and Apple language assets are separate downloads. Their model or system
terms apply independently. No model weights are included in the core application.

LiveLearn's star geometry and UI artwork are project assets. The generated meadow
texture and the adapted scene models have provenance recorded in the Worlds attribution
file and `Assets/Themes/SOURCES.md`. Brand names identify compatibility or source;
they do not imply endorsement.
