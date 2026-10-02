import Foundation
import CaptionDomain

/// Tiny indirection so the prompt helpers read the catalog without every file importing it.
enum CaptionDomainBridge {
    static func englishName(_ code: String) -> String { LanguageCatalog.englishName(code) }
    static func canonical(_ code: String) -> String { LanguageCatalog.canonical(code) }
    static func name(_ code: String?) -> String { LanguageCatalog.name(code) }
}

/// PCM helpers shared by the streaming recognizers.
enum PCM16 {
    /// Float samples (−1…1) to little-endian Int16 bytes.
    static func data(from mono: [Float]) -> Data {
        var out = Data(count: mono.count * 2)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for (i, v) in mono.enumerated() {
                let c = max(-1, min(1, v))
                p[i] = Int16((c * 32767).rounded()).littleEndian
            }
        }
        return out
    }
}
