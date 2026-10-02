import Foundation

/// Foundation inflates raw DEFLATE (`.zlib`) but not gzip; a gzip member is a 10-byte header,
/// optional fields, the DEFLATE stream, and an 8-byte trailer. Only inflation is needed: the
/// app never compresses, and servers that mirror the client's choice send plain JSON back.
enum Gzip {
    static func isGzip(_ data: Data) -> Bool {
        data.count >= 18 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    static func inflate(_ data: Data) throws -> Data {
        guard isGzip(data), data[data.startIndex + 2] == 8 else { throw GzipError.notGzip }
        let bytes = [UInt8](data)
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard offset + 2 <= bytes.count else { throw GzipError.truncated }
            let len = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + len
        }
        if flags & 0x08 != 0 {  // FNAME
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {  // FCOMMENT
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }  // FHCRC
        guard offset < bytes.count - 8 else { throw GzipError.truncated }
        let body = Data(bytes[offset..<(bytes.count - 8)])
        do {
            return try (body as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw GzipError.corrupt(error.localizedDescription)
        }
    }

    enum GzipError: Error, CustomStringConvertible {
        case notGzip, truncated, corrupt(String)
        var description: String {
            switch self {
            case .notGzip: return "not a gzip stream"
            case .truncated: return "gzip stream truncated"
            case .corrupt(let why): return "gzip stream corrupt: \(why)"
            }
        }
    }
}
