import Foundation

// MARK: - SSM helper wire protocol
//
// Service → helper (stdin): length-prefixed JSON requests.
//   u32 LE payload length, then that many bytes of UTF-8 JSON
//   ({"text": "..."} to synthesize, {"cancel": true} to stop the current
//   synthesis).
//
// Helper → service (stdout): typed binary frames.
//   1 type byte + u32 LE payload length + payload.
//   'S' start — JSON {"rate": <Int>, "channels": <Int>}; sent once per
//       synthesis as soon as the output format is known.
//   'A' audio — 16-bit little-endian mono PCM bytes.
//   'E' end   — synthesis finished (also after a cancelled synthesis).
//   'X' error — UTF-8 message; the synthesis produced no further audio.

// MARK: Frames

public enum HelperFrame: Equatable, Sendable {
    case start(rate: Int, channels: Int)
    case audio(Data)
    case end
    case error(String)
}

private enum FrameType: UInt8 {
    case start = 0x53  // 'S'
    case audio = 0x41  // 'A'
    case end = 0x45  // 'E'
    case error = 0x58  // 'X'
}

public func encodeFrame(_ frame: HelperFrame) -> Data {
    let type: FrameType
    let payload: Data
    switch frame {
    case .start(let rate, let channels):
        type = .start
        payload = try! JSONSerialization.data(withJSONObject: ["rate": rate, "channels": channels])
    case .audio(let pcm):
        type = .audio
        payload = pcm
    case .end:
        type = .end
        payload = Data()
    case .error(let message):
        type = .error
        payload = Data(message.utf8)
    }
    var data = Data(capacity: 5 + payload.count)
    data.append(type.rawValue)
    var length = UInt32(payload.count).littleEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(payload)
    return data
}

/// Incremental decoder for helper stdout frames. Feed arbitrary byte chunks;
/// complete frames are returned in order. Unknown frame types are skipped.
public struct HelperFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ bytes: Data) -> [HelperFrame] {
        buffer.append(contentsOf: bytes)
        var frames: [HelperFrame] = []
        while buffer.count >= 5 {
            let typeByte = buffer[buffer.startIndex]
            let length = buffer.dropFirst().prefix(4).withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
            }
            guard buffer.count >= 5 + length else { break }
            let payload = Data(buffer.dropFirst(5).prefix(length))
            buffer.removeFirst(5 + length)
            guard let type = FrameType(rawValue: typeByte) else { continue }
            switch type {
            case .start:
                if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Int],
                    let rate = object["rate"], let channels = object["channels"]
                {
                    frames.append(.start(rate: rate, channels: channels))
                }
            case .audio:
                frames.append(.audio(payload))
            case .end:
                frames.append(.end)
            case .error:
                frames.append(.error(String(decoding: payload, as: UTF8.self)))
            }
        }
        return frames
    }
}

// MARK: Requests

public struct HelperRequest: Codable, Equatable, Sendable {
    public var text: String?
    public var cancel: Bool?

    public init(text: String? = nil, cancel: Bool? = nil) {
        self.text = text
        self.cancel = cancel
    }
}

public func encodeRequest(_ request: HelperRequest) -> Data {
    let payload = try! JSONEncoder().encode(request)
    var data = Data(capacity: 4 + payload.count)
    var length = UInt32(payload.count).littleEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(payload)
    return data
}

/// Incremental decoder for helper stdin requests. Malformed JSON entries are
/// dropped (the length prefix keeps the stream in sync).
public struct HelperRequestDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ bytes: Data) -> [HelperRequest] {
        buffer.append(contentsOf: bytes)
        var requests: [HelperRequest] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
            }
            guard buffer.count >= 4 + length else { break }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(4 + length)
            if let request = try? JSONDecoder().decode(HelperRequest.self, from: payload) {
                requests.append(request)
            }
        }
        return requests
    }
}
