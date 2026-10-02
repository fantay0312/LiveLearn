# Chatterfly protocol bridge

Independently implemented native protocol adapter for LiveLearn. It does not load, launch,
or embed Tencent's input-method executable, change the selected input method, or read another
application's account store. Audio enters through private stdin; normalized revisions and the
session result leave through stdout.

The source of protocol evidence is the user-supplied Chatterfly 1.0.2.13342 binary under
`doc/语音输入法/豆包输入法/Chatterfly/app/Chatterfly.app`. Static analysis identified:

- The ASR endpoint is `wss://srss.chatterfly.tencent.com:443/srss/v1/speech/streaming_recognize`.
  `ws.chatterfly.tencent.com/ws` belongs to cloud synchronization, not ASR. The chain starts
  at `YuanbaoProductProfile.asrProductionServerURL`, passes through
  `SGMacSpeechASRParamsBuilder.resolveASRServerURL`, and reaches `nsrss::AsrFilter`.
- First TEXT frame: Base64 AES-256-CBC/PKCS#7 encrypted compact JSON. Headers contain
  RSA-3072 OAEP-SHA256/MGF1-SHA256 wrapped AES key and Base64 IV. The OAEP label is empty.
- BINARY audio: 16 kHz mono PCM encoded into 20 ms Opus packets, each preceded by its
  two-byte big-endian length. Last partial audio is padded instead of silently discarded.
- Responses are JSON. `results[].is_final` finalizes a segment. The client sends TEXT `{}`
  on finish and waits for the WebSocket to close; segment finality alone is not session completion.
- The public RSA key was extracted from file offset `0x5696da2`, length 422 (DER SPKI).
  Original SHA-256: `ee7a165320f7fa9efd4a860b324c69cbbd2942dd665c87e9a7be4de46a2222b3`.
  The resource contains the equivalent PKCS#1 public key. It is not an account credential.
- The `speech.ipc.startSpeech` distributed notification starts a microphone diagnostic,
  not the actual recognition session. It is deliberately not used as an ASR implementation.

The live service returned `error.code = 16`, `missing authorization` in the no-token probe.
LiveLearn therefore requires an account Token before starting this provider. Protocol unit
tests and a successful WebSocket connection do not constitute live transcription acceptance.
Full audio recognition/finality validation remains pending a valid account credential.

Build: `swift build -c release`; tests: `swift test`. Packaging is owned by
`script/build_chatterfly.sh` and the project's formal `script/build_and_run.sh`.
The bridge uses macOS 26+ because the current packaged Opus library has that deployment target.

No transcript or authentication token is written to disk in normal use. The optional diagnostic
probe is explicit, accepts a PCM file, and was run only with assistant-generated fixture audio.
