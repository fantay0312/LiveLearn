import Foundation

public enum ChatterflyFailure: Error { case invalidConfiguration, encryption, audio, invalidResponse, server(Int) }

public enum ChatterflyConfiguration {
    public static let endpoint = URL(string: "wss://srss.chatterfly.tencent.com:443/srss/v1/speech/streaming_recognize")!

    public static func request(deviceID: String, sessionID: String) -> [String: Any] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return ["interim_results": true, "single_utterance": false, "config": [
            "encoding": "OPUS_WITH_HEADER", "language_code": "zh-cmn-Hans-CN", "result_form": "ONLY_ONE",
            "speech_contexts": [], "enable_word_time_offsets": false, "punctuation_mode": "NORMAL_PUNCTUATION",
            "model": "default", "enable_ambient_sound_event": false, "convert_number": true,
            "unit_symbol_type": 1, "original_audio": false, "custom_info": [:], "client_itn_switch": true,
            "user_feature": ["context": "{\"app_name\":\"LiveLearn\",\"windows_title\":\"\"}", "app_id": 0],
            "functions_switch": ["short_utterance_switch": "0", "enable_streaming_punctuations": "1",
                                 "voice_multi_cands_3de": "1", "voice_multi_cands_3ta": "1"],
            "metadata": [
                "client_info": ["product_category": "sogou_ime", "product_id": "macos_trunk", "product_version": "1.0.2.13342"],
                "host_device_info": ["device_category": "pc", "device_uuid": deviceID, "device_aid": deviceID, "device_qid": deviceID],
                "host_os_info": ["os_category": "darwin", "os_id": "UNSPECIFIED", "os_version": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"],
                "runtime_info": ["consumer_product_id": "com.fantasy.livelearn", "consumer_input_type": "UNSPECIFIED", "consumer_purpose": "UNSPECIFIED"],
                "sdk_info": ["sdk_category": "sogou_ime", "sdk_id": "macOS", "sdk_version": "v1.9.4"],
                "user_info": ["user_category": "anonymous", "user_id": "anonymous", "user_ceip": false],
                "audio_info": ["audio_id": sessionID, "audio_slice_id": "\(sessionID)-0"],
            ],
        ]]
    }
}
