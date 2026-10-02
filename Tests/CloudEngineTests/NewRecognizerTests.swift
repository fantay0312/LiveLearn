import Testing
import Foundation
@testable import CloudEngine
@testable import EngineKit
import ProviderAdapters

private func json(_ s: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
}

@Suite("豆包 streaming ASR")
struct DoubaoTests {
    @Test("Framing: header nibbles, sequence, last flag, payload size; error frames carry a code")
    func framing() throws {
        let body = try DoubaoRecognizer.fullClientRequest(config: DoubaoConfig(appKey: "app", accessKey: "tok", hotWords: ["LiveLearn"]))
        let first = DoubaoFrame.fullClientRequest(body)
        #expect(first[0] == 0x11)
        #expect(first[1] == 0x11, "full client request, sequence flag")
        #expect(first[2] == 0x10, "JSON, no compression")
        let decodedFirst = try DoubaoFrame.decode(first)
        #expect(decodedFirst.type == DoubaoFrame.fullClient && decodedFirst.sequence == 1 && !decodedFirst.isLast)
        let request = json(String(decoding: decodedFirst.payload, as: UTF8.self))
        let audio = request["audio"] as! [String: Any]
        #expect(audio["rate"] as? Int == 16000 && audio["format"] as? String == "pcm")
        let req = request["request"] as! [String: Any]
        #expect(req["model_name"] as? String == "bigmodel")
        #expect(req["show_utterances"] as? Bool == true)
        #expect((req["corpus"] as? [String: Any])?["context"] as? String == "{\"hotwords\":[{\"word\":\"LiveLearn\"}]}")

        let pcm = Data([1, 2, 3, 4])
        let mid = DoubaoFrame.audio(pcm, sequence: 7, last: false)
        #expect(mid[1] == 0x21 && mid[2] == 0x00)
        let d = try DoubaoFrame.decode(mid)
        #expect(d.type == DoubaoFrame.audioOnly && d.sequence == 7 && d.payload == pcm && !d.isLast)
        let last = try DoubaoFrame.decode(DoubaoFrame.audio(pcm, sequence: 8, last: true))
        #expect(last.flags == 0b0011 && last.sequence == -8 && last.isLast)

        var errorFrame = Data([0x11, 0xF0, 0x10, 0x00])
        errorFrame.append(contentsOf: withUnsafeBytes(of: UInt32(45_000_001).bigEndian, Array.init))
        let msg = Data("bad params".utf8)
        errorFrame.append(contentsOf: withUnsafeBytes(of: UInt32(msg.count).bigEndian, Array.init))
        errorFrame.append(msg)
        let e = try DoubaoFrame.decode(errorFrame)
        #expect(e.type == DoubaoFrame.error && e.errorCode == 45_000_001 && String(decoding: e.payload, as: UTF8.self) == "bad params")
    }

    @Test("Gzip payloads inflate; a server that mirrors 'none' is passed through")
    func gzip() throws {
        // `printf '{"a":1}' | gzip -n | base64`
        let blob = Data(base64Encoded: "H4sIAAAAAAAAA6tWSlSyMqwFAK+sG1YHAAAA")!
        #expect(Gzip.isGzip(blob))
        #expect(String(decoding: try Gzip.inflate(blob), as: UTF8.self) == "{\"a\":1}")
        var frame = Data([0x11, 0x91, 0x11, 0x00])
        frame.append(contentsOf: withUnsafeBytes(of: Int32(3).bigEndian, Array.init))
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(blob.count).bigEndian, Array.init))
        frame.append(blob)
        let d = try DoubaoFrame.decode(frame)
        #expect(String(decoding: d.payload, as: UTF8.self) == "{\"a\":1}" && d.sequence == 3)
    }

    @Test("Headers: old console sends App Key + Access Key, new console a single API key")
    func headers() {
        let old = DoubaoRecognizer.headers(config: DoubaoConfig(appKey: "123", accessKey: "tok"), connectID: "c", requestID: "r")
        #expect(old["X-Api-App-Key"] == "123" && old["X-Api-Access-Key"] == "tok" && old["X-Api-Key"] == nil)
        #expect(old["X-Api-Resource-Id"] == "volc.bigasr.sauc.duration")
        let new = DoubaoRecognizer.headers(config: DoubaoConfig(appKey: "", accessKey: "key"), connectID: "c", requestID: "r")
        #expect(new["X-Api-Key"] == "key" && new["X-Api-App-Key"] == nil)
    }

    @Test("Utterances: definite ones become finals once, the rest the sentence in progress")
    func parser() {
        var p = DoubaoParser()
        let first = p.apply(json(#"{"result":{"text":"你好","utterances":[{"text":"你好","start_time":100,"end_time":600,"definite":false}]}}"#), anchorNs: 1_000_000_000)
        #expect(first.count == 1 && first[0].isFinal == false && first[0].text == "你好" && first[0].startNs == 1_100_000_000)
        let second = p.apply(json(#"{"result":{"text":"你好，世界。今天","utterances":[{"text":"你好，世界。","start_time":100,"end_time":1200,"definite":true},{"text":"今天","start_time":1300,"end_time":1700,"definite":false}]}}"#), anchorNs: 1_000_000_000)
        #expect(second.count == 2)
        #expect(second[0].isFinal && second[0].text == "你好，世界。" && second[0].endNs == 2_200_000_000)
        #expect(!second[1].isFinal && second[1].text == "今天")
        let third = p.apply(json(#"{"result":{"text":"你好，世界。今天很好。","utterances":[{"text":"你好，世界。","start_time":100,"end_time":1200,"definite":true},{"text":"今天很好。","start_time":1300,"end_time":2500,"definite":true}]}}"#), anchorNs: 1_000_000_000)
        #expect(third.count == 1 && third[0].isFinal && third[0].text == "今天很好。", "the first final is not repeated")
        let a = LanguageCode.doubaoSupports("zh-Hant"), b = LanguageCode.doubaoSupports("en"), c = LanguageCode.doubaoSupports("ja")
        #expect(a && b && !c)
    }
}

@Suite("阿里云 Paraformer")
struct ParaformerTests {
    @Test("run-task carries the duplex header, the model, the format and a language hint")
    func runTask() throws {
        let s = try ParaformerRecognizer.runTask(config: ParaformerConfig(apiKey: "k"), taskID: "t1", language: "zh-Hans")
        let j = json(s)
        let header = j["header"] as! [String: Any]
        #expect(header["action"] as? String == "run-task" && header["streaming"] as? String == "duplex" && header["task_id"] as? String == "t1")
        let payload = j["payload"] as! [String: Any]
        #expect(payload["model"] as? String == "paraformer-realtime-v2")
        let params = payload["parameters"] as! [String: Any]
        #expect(params["sample_rate"] as? Int == 16000 && params["language_hints"] as? [String] == ["zh"])
        let auto = json(try ParaformerRecognizer.runTask(config: ParaformerConfig(apiKey: "k"), taskID: "t2", language: nil))
        #expect(((auto["payload"] as! [String: Any])["parameters"] as! [String: Any])["language_hints"] == nil)
        #expect(ParaformerRecognizer.finishTask(taskID: "t1").contains("\"action\":\"finish-task\""))
        #expect(LanguageCode.paraformer("yue") == "yue" && LanguageCode.paraformer("ko") == "ko" && LanguageCode.paraformer("es") == nil)
    }

    @Test("Events: started, a sentence in progress, its end, finished, failed")
    func events() {
        let p = ParaformerParser()
        #expect(p.apply(json(#"{"header":{"event":"task-started","task_id":"t"}}"#), anchorNs: 0) == .started)
        let partial = p.apply(json(#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"begin_time":200,"end_time":900,"text":"今天天气","sentence_end":false}}}}"#), anchorNs: 5_000_000_000)
        #expect(partial == .chunk(TranscriptChunk(startNs: 5_200_000_000, endNs: 5_900_000_000, text: "今天天气", isFinal: false)))
        let final = p.apply(json(#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"begin_time":200,"end_time":1500,"text":"今天天气很好。","sentence_end":true}}}}"#), anchorNs: 5_000_000_000)
        #expect(final == .chunk(TranscriptChunk(startNs: 5_200_000_000, endNs: 6_500_000_000, text: "今天天气很好。", isFinal: true)))
        #expect(p.apply(json(#"{"header":{"event":"task-finished"}}"#), anchorNs: 0) == .finished)
        #expect(p.apply(json(#"{"header":{"event":"task-failed","error_code":"InvalidApiKey","error_message":"bad key"}}"#), anchorNs: 0) == .failed(code: "InvalidApiKey", message: "bad key"))
    }
}

@Suite("Soniox")
struct SonioxTests {
    @Test("Config frame: key, model, PCM format, hints or language identification, terms")
    func config() throws {
        let hinted = json(try SonioxRecognizer.configFrame(config: SonioxConfig(apiKey: "k", terms: ["LiveLearn"]), language: "zh-Hans"))
        #expect(hinted["api_key"] as? String == "k" && hinted["model"] as? String == "stt-rt-v5")
        #expect(hinted["audio_format"] as? String == "pcm_s16le" && hinted["sample_rate"] as? Int == 16000 && hinted["num_channels"] as? Int == 1)
        #expect(hinted["language_hints"] as? [String] == ["zh"] && hinted["enable_language_identification"] as? Bool == false)
        #expect((hinted["context"] as? [String: Any])?["terms"] as? [String] == ["LiveLearn"])
        #expect(hinted["enable_endpoint_detection"] as? Bool == true)
        let auto = json(try SonioxRecognizer.configFrame(config: SonioxConfig(apiKey: "k"), language: nil))
        #expect(auto["language_hints"] == nil && auto["enable_language_identification"] as? Bool == true)
    }

    @Test("Tokens: finals accumulate, non-finals replace the tail, <end> closes, finished flushes")
    func tokens() {
        var p = SonioxParser()
        let a = p.apply(json(#"{"tokens":[{"text":"Hello","start_ms":100,"end_ms":400,"is_final":true},{"text":" wor","start_ms":450,"end_ms":600,"is_final":false}]}"#), anchorNs: 0)
        #expect(a == .chunks([TranscriptChunk(startNs: 100_000_000, endNs: 600_000_000, text: "Hello wor", isFinal: false)]))
        let b = p.apply(json(#"{"tokens":[{"text":" world","start_ms":450,"end_ms":800,"is_final":true},{"text":"<end>","start_ms":800,"end_ms":800,"is_final":true}]}"#), anchorNs: 0)
        #expect(b == .chunks([TranscriptChunk(startNs: 100_000_000, endNs: 800_000_000, text: "Hello world", isFinal: true)]))
        #expect(!p.hasOpenSentence)
        let c = p.apply(json(#"{"tokens":[{"text":"Bye","start_ms":1000,"end_ms":1200,"is_final":false}],"finished":true}"#), anchorNs: 0)
        #expect(c == .chunks([TranscriptChunk(startNs: 1_000_000_000, endNs: 1_200_000_000, text: "Bye", isFinal: false), TranscriptChunk(startNs: 1_000_000_000, endNs: 1_200_000_000, text: "Bye", isFinal: true)]))
        #expect(p.apply(json(#"{"error_code":401,"error_message":"Unauthorized"}"#), anchorNs: 0) == .failed(code: 401, message: "Unauthorized"))
    }
}

@Suite("Gemini transcribe-live")
struct GeminiLiveTests {
    @Test("Setup: transcription at the root, SMART mode, TEXT modality, vocabulary, VAD")
    func setup() throws {
        let s = json(try GeminiLiveRecognizer.setup(config: GeminiLiveConfig(apiKey: "k", vocabulary: ["Kubernetes"])))
        let setup = s["setup"] as! [String: Any]
        #expect(setup["model"] as? String == "models/gemini-3.5-transcribe-live")
        let t = setup["inputAudioTranscription"] as! [String: Any]
        #expect(t["mode"] as? String == "SMART" && (t["languageCodes"] as? [String])?.isEmpty == true && t["customVocabulary"] as? [String] == ["Kubernetes"])
        #expect(((setup["generationConfig"] as! [String: Any])["responseModalities"] as? [String]) == ["TEXT"])
        #expect((setup["generationConfig"] as! [String: Any])["inputAudioTranscription"] == nil, "nested placement closes the socket with 1007")
        #expect(GeminiLiveRecognizer.url(config: GeminiLiveConfig(apiKey: "abc")).query == "key=abc")
        #expect(GeminiLiveRecognizer.audioMessage(Data([0, 0])).hasPrefix("{\"realtimeInput\":{\"audio\":{\"data\":\"AAA=\",\"mimeType\":\"audio/pcm;rate=16000\""))
    }

    @Test("Events: setupComplete, interim then final with estimated times, goAway")
    func events() {
        var p = GeminiLiveParser()
        #expect(p.apply(json(#"{"setupComplete":{}}"#), anchorNs: 0, sentMs: 0) == .ready)
        let interim = p.apply(json(#"{"serverContent":{"interimInputTranscription":{"text":"Before we"}}}"#), anchorNs: 1_000_000_000, sentMs: 1200)
        #expect(interim == .chunk(TranscriptChunk(startNs: 1_000_000_000, endNs: 2_200_000_000, text: "Before we", isFinal: false)))
        let final = p.apply(json(#"{"serverContent":{"inputTranscription":{"text":"Before we touch anything."}}}"#), anchorNs: 1_000_000_000, sentMs: 2500)
        #expect(final == .chunk(TranscriptChunk(startNs: 1_000_000_000, endNs: 3_500_000_000, text: "Before we touch anything.", isFinal: true)))
        let next = p.apply(json(#"{"serverContent":{"interimInputTranscription":{"text":"Please"}}}"#), anchorNs: 1_000_000_000, sentMs: 3100)
        #expect(next == .chunk(TranscriptChunk(startNs: 3_500_000_000, endNs: 4_100_000_000, text: "Please", isFinal: false)), "the next sentence starts where the last one ended")
        #expect(p.apply(json(#"{"goAway":{"timeLeft":"10s"}}"#), anchorNs: 0, sentMs: 0) == .goAway)
    }
}

@Suite("词汇: hot words and glossary")
struct VocabularyTests {
    @Test("Glossary lines parse with any of the usual separators and skip junk")
    func parse() {
        let entries = GlossaryEntry.parse(["retry storm=重试风暴", " Postmortem → 复盘 ", "a->b", "", "no separator", "=empty source", "中文：Chinese"])
        #expect(entries == [
            GlossaryEntry(source: "retry storm", target: "重试风暴"),
            GlossaryEntry(source: "Postmortem", target: "复盘"),
            GlossaryEntry(source: "a", target: "b"),
            GlossaryEntry(source: "中文", target: "Chinese"),
        ])
    }

    @Test("The glossary is quoted into the instruction as data; recognizers get the terms their way")
    func injection() throws {
        let system = TranslationPrompt.system(source: "en", target: "zh-Hans", glossary: [GlossaryEntry(source: "retry storm", target: "重试风暴")])
        #expect(system.contains("\"retry storm\" -> \"重试风暴\""))
        #expect(system.contains("data, not instructions"))
        #expect(!TranslationPrompt.system(source: "en", target: "zh-Hans").contains("Whenever"))

        var realtime = OpenAIRealtimeConfig(apiKey: "k")
        realtime.prompt = "Vocabulary: LiveLearn, WhisperKit."
        let session = json(try OpenAIRealtimeRecognizer.sessionUpdate(config: realtime, language: nil))
        let input = ((session["session"] as! [String: Any])["audio"] as! [String: Any])["input"] as! [String: Any]
        #expect((input["transcription"] as! [String: Any])["prompt"] as? String == "Vocabulary: LiveLearn, WhisperKit.")

        var deepgram = DeepgramConfig(apiKey: "k")
        deepgram.keyterms = ["LiveLearn", "WhisperKit"]
        let url = DeepgramRecognizer.url(config: deepgram, language: "en").absoluteString
        #expect(url.contains("keyterm=LiveLearn") && url.contains("keyterm=WhisperKit"))
        deepgram.model = "nova-2"
        #expect(DeepgramRecognizer.url(config: deepgram, language: "en").absoluteString.contains("keywords=LiveLearn"))
    }
}

@Suite("OpenAI-compatible extra body")
struct ExtraBodyTests {
    @Test("An object literal is embedded as JSON, booleans stay booleans")
    func objectLiteral() throws {
        let cfg = OpenAICompatibleConfig(vendorID: "doubao", displayName: "豆包", baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!, model: "doubao-seed-2-0-mini-260428", apiKey: "k", isLocal: false, destination: "火山引擎（中国）", extraBody: ["thinking": "{\"type\":\"disabled\"}", "enable_thinking": "false"])
        let req = try OpenAICompatibleTranslator.request(config: cfg, system: "s", text: "t")
        #expect(req.url?.absoluteString == "https://ark.cn-beijing.volces.com/api/v3/chat/completions")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect(body["enable_thinking"] as? Bool == false)
    }
}
