import Foundation
import Security
import CommonCrypto

public struct ChatterflyEncryptedConfiguration {
    public let text: String
    public let headers: [String: String]
}

public enum ChatterflyCipher {
    public static var resourcePath: String { Bundle.module.bundlePath }
    public static func publicKey() throws -> SecKey {
        guard let url = Bundle.module.url(forResource: "ServerPublicKey", withExtension: "der") else { throw ChatterflyFailure.encryption }
        let der = try Data(contentsOf: url)
        guard let key = SecKeyCreateWithData(der as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil) else { throw ChatterflyFailure.encryption }
        return key
    }

    public static func encrypt(_ configuration: [String: Any], publicKey: SecKey? = nil) throws -> ChatterflyEncryptedConfiguration {
        var key = Data(count: 32), iv = Data(count: 16)
        guard key.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess,
              iv.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else { throw ChatterflyFailure.encryption }
        let plaintext = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys, .withoutEscapingSlashes])
        let cipher = try aes(plaintext, key: key, iv: iv, encrypt: true)
        let rsa = try publicKey ?? Self.publicKey()
        guard let wrapped = SecKeyCreateEncryptedData(rsa, .rsaEncryptionOAEPSHA256, key as CFData, nil) as Data? else { throw ChatterflyFailure.encryption }
        return .init(text: cipher.base64EncodedString(), headers: ["X-Srss-Cipher-Key-Type": "1",
            "X-Srss-Cipher-Key-Sec": wrapped.base64EncodedString(), "X-Srss-Cipher-Key-Vec": iv.base64EncodedString()])
    }

    static func aes(_ data: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
        guard key.count == 32, iv.count == 16 else { throw ChatterflyFailure.encryption }
        var output = Data(count: data.count + kCCBlockSizeAES128), count = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
                CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress, key.count, v.baseAddress, input.baseAddress, data.count, out.baseAddress, capacity, &count)
            } } }
        }
        guard status == kCCSuccess else { throw ChatterflyFailure.encryption }
        output.count = count
        return output
    }
}
