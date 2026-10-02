import Foundation
import CryptoKit

// Private keys stay outside the repository. Only the public trust record is shipped.
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    fatalError("Usage: swift script/module_signing.swift keygen PRIVATE_KEY TRUST_JSON | sign PRIVATE_KEY PAYLOAD_JSON OUTPUT_JSON")
}
let keyURL = URL(fileURLWithPath: args[1])
if args[0] == "keygen" {
    let key: Curve25519.Signing.PrivateKey
    if FileManager.default.fileExists(atPath: keyURL.path) {
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
    } else {
        key = Curve25519.Signing.PrivateKey()
        try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.rawRepresentation.write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }
    let record = ["catalogURL": "https://github.com/fantay0312/LiveLearn/releases/download/modules-v1/catalog.json",
                  "publicKey": key.publicKey.rawRepresentation.base64EncodedString()]
    try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: args[2]), options: .atomic)
    print("Public trust record written; private key retained outside the repository.")
} else if args[0] == "sign", args.count == 4 {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
    let payload = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let envelope = ["payload": payload.base64EncodedString(), "signature": try key.signature(for: payload).base64EncodedString()]
    try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: args[3]), options: .atomic)
    print("Catalog signed.")
} else { fatalError("Unknown command") }
