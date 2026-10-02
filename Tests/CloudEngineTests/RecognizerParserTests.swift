import Testing
import Foundation
@testable import CloudEngine
@testable import EngineKit
import ProviderAdapters

private func json(_ s: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
}

@Suite("OpenAI Realtime transcription")
struct OpenAIRealtimeTests {
    @Test("Cloud transcripts retain mishearings for explicit local review", arguments: ["Open live lawn.", "用飞鼠开会。"])
    func vocabularyCandidatesPreserveCloudText(text: String) throws {
        var parser = OpenAIRealtimeParser()
        let output = parser.apply(["type": "conversation.item.input_audio_transcription.completed", "item_id": "vocab", "transcript": text],
                                  anchorNs: 0, sentMs: 1000)
        guard case .chunk(let chunk) = output else { Issue.record("Expected a completed transcript"); return }
        #expect(chunk.isFinal && chunk.text == text)
        let candidates = VocabularyCandidateGenerator(vocabulary: ["LiveLearn", "飞书"]).candidates(in: chunk.text)
        #expect(candidates.count == 1)
        #expect(chunk.text == text)
    }

    @Test("URL: OpenAI gets intent only; compatible servers also get the model")
    func url() {
        let openai = OpenAIRealtimeRecognizer.url(config: OpenAIRealtimeConfig(apiKey: "k"))
        #expect(openai.absoluteString == "wss://api.openai.com/v1/realtime?intent=transcription")
        let compatible = OpenAIRealtimeRecognizer.url(config: OpenAIRealtimeConfig(baseURL: URL(string: "ws://localhost:8000/v1/realtime")!, apiKey: nil, model: "Systran/faster-whisper-small", legacyProtocol: true))
        #expect(compatible.absoluteString == "ws://localhost:8000/v1/realtime?intent=transcription&model=Systran/faster-whisper-small")
    }

    @Test("Session update: GA shape with server VAD and 24 kHz PCM; legacy flat shape on request")
    func sessionUpdate() throws {
        let ga = json(try OpenAIRealtimeRecognizer.sessionUpdate(config: OpenAIRealtimeConfig(apiKey: "k"), language: "zh-Hans"))
        #expect(ga["type"] as? String == "session.update")
        let session = ga["session"] as! [String: Any]
        #expect(session["type"] as? String == "transcription")
        let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
        #expect((input["format"] as! [String: Any])["rate"] as? Int == 24000)
        #expect((input["transcription"] as! [String: Any])["language"] as? String == "zh")
        #expect((input["turn_detection"] as! [String: Any])["type"] as? String == "server_vad")
        let legacy = json(try OpenAIRealtimeRecognizer.sessionUpdate(config: OpenAIRealtimeConfig(apiKey: "k", legacyProtocol: true), language: nil))
        #expect(legacy["type"] as? String == "transcription_session.update")
        let ls = legacy["session"] as! [String: Any]
        #expect(ls["input_audio_format"] as? String == "pcm16")
        #expect((ls["input_audio_transcription"] as! [String: Any])["language"] == nil)
        #expect(OpenAIRealtimeRecognizer.appendEvent(Data([0, 0])).hasPrefix("{\"type\":\"input_audio_buffer.append\",\"audio\":\"AAA=\""))
    }

    @Test("Events: VAD timing frames the deltas and the completed transcript; errors are classified")
    func events() {
        var p = OpenAIRealtimeParser()
        let anchor: Int64 = 5_000_000_000
        #expect(p.apply(json(#"{"type":"session.created"}"#), anchorNs: anchor, sentMs: 0) == .sessionReady)
        #expect(p.apply(json(#"{"type":"input_audio_buffer.speech_started","item_id":"i1","audio_start_ms":1200}"#), anchorNs: anchor, sentMs: 1500) == .none)
        let d1 = p.apply(json(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"i1","delta":"Hello"}"#), anchorNs: anchor, sentMs: 2000)
        #expect(d1 == .chunk(TranscriptChunk(startNs: anchor + 1_200_000_000, endNs: anchor + 2_000_000_000, text: "Hello", isFinal: false)))
        let d2 = p.apply(json(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"i1","delta":" world"}"#), anchorNs: anchor, sentMs: 2500)
        #expect(d2 == .chunk(TranscriptChunk(startNs: anchor + 1_200_000_000, endNs: anchor + 2_500_000_000, text: "Hello world", isFinal: false)))
        #expect(p.apply(json(#"{"type":"input_audio_buffer.speech_stopped","item_id":"i1","audio_end_ms":2900}"#), anchorNs: anchor, sentMs: 3000) == .none)
        let done = p.apply(json(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i1","transcript":"Hello world."}"#), anchorNs: anchor, sentMs: 3200)
        #expect(done == .chunk(TranscriptChunk(startNs: anchor + 1_200_000_000, endNs: anchor + 2_900_000_000, text: "Hello world.", isFinal: true)))
        #expect(p.items.isEmpty)
        let err = p.apply(json(#"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_api_key","message":"Incorrect API key provided"}}"#), anchorNs: anchor, sentMs: 0)
        guard case .error(let e) = err else { Issue.record("expected error"); return }
        #expect(e.classification == .userFixable)
        #expect(e.message.contains("Incorrect API key"))
        let busy = p.apply(json(#"{"type":"error","error":{"type":"server_error","code":"","message":"overloaded"}}"#), anchorNs: anchor, sentMs: 0)
        guard case .error(let b) = busy else { Issue.record("expected error"); return }
        #expect(b.classification == .retryable)
    }
}

@Suite("Deepgram streaming")
struct DeepgramTests {
    @Test("URL carries the PCM parameters and the vendor's language tags")
    func url() {
        let u = DeepgramRecognizer.url(config: DeepgramConfig(apiKey: "k"), language: "zh-Hans").absoluteString
        #expect(u.hasPrefix("wss://api.deepgram.com/v1/listen?model=nova-3&encoding=linear16&sample_rate=16000&channels=1&language=zh-CN&interim_results=true"))
        #expect(DeepgramRecognizer.url(config: DeepgramConfig(apiKey: "k"), language: nil).absoluteString.contains("language=multi"))
        #expect(DeepgramRecognizer.url(config: DeepgramConfig(apiKey: "k"), language: "yue").absoluteString.contains("language=zh-HK"))
        #expect(DeepgramRecognizer.url(config: DeepgramConfig(apiKey: "k"), language: "nb").absoluteString.contains("language=no"))
    }

    @Test("Interim replaces the tail, finals accumulate, speech_final closes with word timing")
    func results() {
        var p = DeepgramParser()
        let anchor: Int64 = 1_000_000_000
        let interim = p.apply(json(#"{"type":"Results","start":0.5,"duration":1.0,"is_final":false,"speech_final":false,"channel":{"alternatives":[{"transcript":"tell me","words":[{"word":"tell","start":0.6,"end":0.8},{"word":"me","start":0.8,"end":0.9}]}]}}"#), anchorNs: anchor)
        #expect(interim == .chunk(TranscriptChunk(startNs: anchor + 600_000_000, endNs: anchor + 900_000_000, text: "tell me", isFinal: false)))
        let settled = p.apply(json(#"{"type":"Results","start":0.5,"duration":1.5,"is_final":true,"speech_final":false,"channel":{"alternatives":[{"transcript":"Tell me more","words":[{"word":"tell","start":0.6,"end":0.8},{"word":"more","start":1.1,"end":1.4}]}]}}"#), anchorNs: anchor)
        #expect(settled == .chunk(TranscriptChunk(startNs: anchor + 600_000_000, endNs: anchor + 1_400_000_000, text: "Tell me more", isFinal: false)))
        let tail = p.apply(json(#"{"type":"Results","start":2.0,"duration":0.8,"is_final":false,"speech_final":false,"channel":{"alternatives":[{"transcript":"about","words":[{"word":"about","start":2.1,"end":2.4}]}]}}"#), anchorNs: anchor)
        #expect(tail == .chunk(TranscriptChunk(startNs: anchor + 600_000_000, endNs: anchor + 2_400_000_000, text: "Tell me more about", isFinal: false)))
        let final = p.apply(json(#"{"type":"Results","start":2.0,"duration":1.2,"is_final":true,"speech_final":true,"channel":{"alternatives":[{"transcript":"about this.","words":[{"word":"about","start":2.1,"end":2.4},{"word":"this","start":2.5,"end":2.9}]}]}}"#), anchorNs: anchor)
        #expect(final == .chunk(TranscriptChunk(startNs: anchor + 600_000_000, endNs: anchor + 2_900_000_000, text: "Tell me more about this.", isFinal: true)))
        #expect(!p.hasOpenSentence)
        // Nothing open: an UtteranceEnd after speech_final is ignored.
        #expect(p.apply(json(#"{"type":"UtteranceEnd","channel":[0,1],"last_word_end":2.9}"#), anchorNs: anchor) == .none)
    }

    @Test("UtteranceEnd closes an open sentence when no speech_final came; CJK joins without spaces")
    func utteranceEnd() {
        var p = DeepgramParser()
        _ = p.apply(json(#"{"type":"Results","start":0,"duration":1,"is_final":true,"speech_final":false,"channel":{"alternatives":[{"transcript":"请先不要","words":[{"word":"请先不要","start":0.2,"end":0.9}]}]}}"#), anchorNs: 0)
        _ = p.apply(json(#"{"type":"Results","start":1,"duration":1,"is_final":true,"speech_final":false,"channel":{"alternatives":[{"transcript":"重启服务器。","words":[{"word":"重启服务器。","start":1.1,"end":1.9}]}]}}"#), anchorNs: 0)
        let closed = p.apply(json(#"{"type":"UtteranceEnd","channel":[0,1],"last_word_end":1.95}"#), anchorNs: 0)
        #expect(closed == .chunk(TranscriptChunk(startNs: 200_000_000, endNs: 1_950_000_000, text: "请先不要重启服务器。", isFinal: true)))
        #expect(DeepgramParser.join(["Hello", "world", "你好", "吗"]) == "Hello world你好吗")
    }
}

@Suite("Anthropic translator wire format")
struct AnthropicWireTests {
    @Test("Headers, body and reply")
    func wire() throws {
        let cfg = AnthropicConfig(model: "claude-opus-5", apiKey: "a")
        let req = try AnthropicTranslator.request(config: cfg, system: "S", text: "T")
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "a")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "claude-opus-5")
        #expect(body["system"] as? String == "S")
        #expect((body["messages"] as! [[String: String]])[0]["content"] == "T")
        let reply = #"{"content":[{"type":"text","text":"请先不要重启服务器。"}],"stop_reason":"end_turn"}"#
        #expect(try AnthropicTranslator.parse(Data(reply.utf8)) == "请先不要重启服务器。")
        let refusal = #"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"other"}}"#
        #expect(try AnthropicTranslator.parse(Data(refusal.utf8)) == "")
        let error = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        #expect(throws: ProviderError.self) { try AnthropicTranslator.parse(Data(error.utf8)) }
    }
}

@Suite("PCM16")
struct PCMTests {
    @Test("Floats become little-endian Int16 with clamping")
    func encode() {
        let d = PCM16.data(from: [0, 1, -1, 0.5, 2])
        #expect(d.count == 10)
        let samples = d.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Int16(littleEndian: $0) }
        #expect(samples == [0, 32767, -32767, 16384, 32767])
    }
}
