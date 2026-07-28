import Foundation

public enum FrameError: Error, Equatable {
    case payloadTooLarge(Int)
    case emptyPayload
}

public enum FrameEncoder {
    public static let maximumPayloadSize = 65_536

    public static func encode<Message: Encodable>(
        _ message: Message,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        let payload = try encoder.encode(message)
        guard !payload.isEmpty else { throw FrameError.emptyPayload }
        guard payload.count <= maximumPayloadSize else {
            throw FrameError.payloadTooLarge(payload.count)
        }

        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }
}

public struct FrameDecoder: Sendable {
    private let maximumPayloadSize: Int
    private var buffer = Data()

    public init(maximumPayloadSize: Int = FrameEncoder.maximumPayloadSize) {
        self.maximumPayloadSize = maximumPayloadSize
    }

    public mutating func append<Bytes: DataProtocol>(_ bytes: Bytes) throws -> [Data] {
        buffer.append(contentsOf: bytes)
        var payloads: [Data] = []

        while buffer.count >= MemoryLayout<UInt32>.size {
            let payloadLength = buffer.prefix(4).reduce(0) {
                ($0 << 8) | Int($1)
            }
            guard payloadLength > 0 else { throw FrameError.emptyPayload }
            guard payloadLength <= maximumPayloadSize else {
                throw FrameError.payloadTooLarge(payloadLength)
            }

            let frameLength = 4 + payloadLength
            guard buffer.count >= frameLength else { break }

            let frameStart = buffer.startIndex
            let payloadStart = buffer.index(frameStart, offsetBy: 4)
            let frameEnd = buffer.index(frameStart, offsetBy: frameLength)
            payloads.append(buffer.subdata(in: payloadStart..<frameEnd))
            buffer.removeFirst(frameLength)
        }

        return payloads
    }
}
