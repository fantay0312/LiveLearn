import Foundation
import Security
import Testing
@testable import ChatterflyProtocol

struct ProtocolTests {
    @Test func verifiedServerKeyIsRSA3072() throws {
        let key = try ChatterflyCipher.publicKey()
        let attributes = try #require(SecKeyCopyAttributes(key) as? [String: Any])
        #expect(attributes[kSecAttrKeySizeInBits as String] as? Int == 3072)
    }

    @Test func encryptedConfigurationRoundTripsWithOAEP256AndAESCBC() throws {
        let privateKey = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 3072] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let encrypted = try ChatterflyCipher.encrypt(["interim_results": true, "config": ["language_code": "zh-cmn-Hans-CN"]], publicKey: publicKey)
        let wrapped = try #require(Data(base64Encoded: encrypted.headers["X-Srss-Cipher-Key-Sec"]!))
        #expect(wrapped.count == 384)
        let key = try #require(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, wrapped as CFData, nil) as Data?)
        #expect(key.count == 32)
        let iv = try #require(Data(base64Encoded: encrypted.headers["X-Srss-Cipher-Key-Vec"]!))
        #expect(iv.count == 16)
        let plaintext = try ChatterflyCipher.aes(Data(base64Encoded: encrypted.text)!, key: key, iv: iv, encrypt: false)
        let decoded = try #require(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        #expect(decoded["interim_results"] as? Bool == true)
    }

    @Test func audioHasBigEndianLengthPrefixedTwentyMillisecondPackets() throws {
        let encoder = try ChatterflyAudioFrames()
        #expect(try encoder.append(Data(count: 320)).isEmpty)
        let packets = try encoder.append(Data(count: 1600), finish: true)
        var count = 0, offset = 0
        while offset < packets.count {
            let length = Int(packets[offset]) << 8 | Int(packets[offset + 1])
            #expect(length > 0 && length <= 320)
            offset += 2 + length; count += 1
        }
        #expect(offset == packets.count && count == 3)
    }

    @Test func revisionsReplaceAndFinalsDoNotBecomeSessionDone() throws {
        var transcript = ChatterflyTranscript()
        func packet(_ text: String, final: Bool) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["results": [["start_time": 0, "end_time": 100, "is_final": final, "alternatives": [["transcript": text]]]]])
        }
        #expect(try transcript.receive(packet("配森", final: false)) == "配森")
        #expect(try transcript.receive(packet("Python", final: true)) == "Python")
        #expect(transcript.sawFinal)
        let event = Data(#"{"events":[{"event_type":"END_OF_SINGLE_UTTERANCE"}]}"#.utf8)
        #expect(throws: (any Error).self) { try transcript.receive(event) }
    }

    @Test func contextIsAStringAndSourceFormatIsNotInventedOnWire() throws {
        let body = ChatterflyConfiguration.request(deviceID: "fixture-device", sessionID: "fixture-session")
        let config = try #require(body["config"] as? [String: Any])
        #expect(config["encoding"] as? String == "OPUS_WITH_HEADER")
        #expect((config["user_feature"] as? [String: Any])?["context"] is String)
        #expect(config["sample_rate"] == nil && config["channels"] == nil)
        #expect(body["single_utterance"] as? Bool == false)
        _ = try JSONSerialization.data(withJSONObject: body)
    }
}
