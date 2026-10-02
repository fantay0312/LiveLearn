import Foundation

/// Logs can contain arbitrary translated text. A per-launch token distinguishes actual
/// protocol frames from log lines, including text that resembles a protocol message.
struct TranslationReplyFramer {
    private let prefix: Data
    private var buffer = Data()
    var maximumLineBytes = 2_097_152

    init(token: String) {
        prefix = Data("LIVELEARN_TRANSLATION:\(token):".utf8)
    }

    mutating func append(_ data: Data) throws -> [TranslationReply] {
        buffer.append(data)
        var replies: [TranslationReply] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            guard line.count <= maximumLineBytes else { throw overflow() }
            guard line.starts(with: prefix),
                  let reply = try? JSONDecoder().decode(TranslationReply.self, from: line.dropFirst(prefix.count)) else { continue }
            replies.append(reply)
        }
        guard buffer.count <= maximumLineBytes else { throw overflow() }
        return replies
    }

    private mutating func overflow() -> TranslationFeatureError {
        buffer.removeAll(keepingCapacity: false)
        return .unavailable("翻译模块返回了过大的响应。")
    }
}
