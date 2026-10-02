import Foundation
import COpus

public final class ChatterflyAudioFrames {
    private let encoder: OpaquePointer
    private var pending = Data()
    public init() throws {
        var error: Int32 = 0
        guard let encoder = opus_encoder_create(16000, 1, 2048, &error), error == 0 else { throw ChatterflyFailure.audio }
        self.encoder = encoder
    }
    deinit { opus_encoder_destroy(encoder) }

    public func append(_ pcm: Data, finish: Bool = false) throws -> Data {
        pending.append(pcm)
        guard pending.count <= 1_048_576 else { throw ChatterflyFailure.audio }
        if finish, !pending.isEmpty, pending.count % 640 != 0 { pending.append(Data(count: 640 - pending.count % 640)) }
        var output = Data()
        while pending.count >= 640 {
            let bytes = Array(pending.prefix(640))
            let samples: [Int16] = stride(from: 0, to: 640, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
            var encoded = [UInt8](repeating: 0, count: 4000)
            let size = samples.withUnsafeBufferPointer { input in
                encoded.withUnsafeMutableBufferPointer { opus_encode(encoder, input.baseAddress!, 320, $0.baseAddress!, Int32($0.count)) }
            }
            guard size > 0, size <= 320 else { throw ChatterflyFailure.audio }
            output.append(UInt8((size >> 8) & 255)); output.append(UInt8(size & 255))
            output.append(contentsOf: encoded.prefix(Int(size)))
            pending.removeFirst(640)
        }
        return output
    }
}
