import Foundation

// MARK: - AIFF chunk parsing

/// Stream parameters of an AIFF file, extracted from its header prefix.
public struct AIFFStreamInfo: Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    /// Byte offset of the first audio sample (start of the SSND sound data,
    /// after the offset/blockSize fields and any alignment offset).
    public let payloadOffset: Int

    public init(sampleRate: Int, channels: Int, bitsPerSample: Int, payloadOffset: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.payloadOffset = payloadOffset
    }
}

/// Locates the SSND audio payload in an AIFF/AIFC byte prefix and extracts
/// the stream parameters from the COMM chunk.
///
/// Returns `nil` when the prefix is too short to reach both the COMM chunk
/// and the SSND chunk header (callers tailing a growing file should wait for
/// more bytes) or when the bytes are not an AIFF stream at all. All chunk
/// sizes are big-endian per the AIFF spec; odd-sized chunks are followed by a
/// pad byte. The Speech Synthesis Manager pads the header with intermediate
/// chunks (observed: payload at offset 4096), so the walker skips unknown
/// chunks rather than assuming a fixed layout.
public func aiffStreamInfo(in bytes: Data) -> AIFFStreamInfo? {
    let data = Data(bytes)  // re-base so integer offsets are valid for any slice
    guard data.count >= 12,
        data[0..<4] == Data("FORM".utf8),
        data[8..<12] == Data("AIFF".utf8) || data[8..<12] == Data("AIFC".utf8)
    else { return nil }

    var pos = 12
    var comm: (rate: Int, channels: Int, bits: Int)?
    while pos + 8 <= data.count {
        let chunkID = data[pos..<(pos + 4)]
        let size = Int(beUInt32(data, at: pos + 4))
        let bodyStart = pos + 8

        if chunkID == Data("COMM".utf8) {
            guard bodyStart + 18 <= data.count else { return nil }
            let channels = Int(beUInt16(data, at: bodyStart))
            let bits = Int(beUInt16(data, at: bodyStart + 6))
            let rate = parseExtended80(data, at: bodyStart + 8)
            comm = (Int(rate.rounded()), channels, bits)
        }
        else if chunkID == Data("SSND".utf8) {
            // Need the offset + blockSize fields (8 bytes) of the SSND body.
            guard bodyStart + 8 <= data.count else { return nil }
            guard let comm else { return nil }
            let offset = Int(beUInt32(data, at: bodyStart))
            return AIFFStreamInfo(
                sampleRate: comm.rate,
                channels: comm.channels,
                bitsPerSample: comm.bits,
                payloadOffset: bodyStart + 8 + offset
            )
        }

        pos = bodyStart + size + (size & 1)
    }
    return nil
}

/// Converts 16-bit big-endian PCM (AIFF sample layout) to little-endian.
/// Expects an even byte count; a trailing odd byte is dropped.
public func pcm16BigEndianToLittleEndian(_ data: Data) -> Data {
    let input = Data(data)
    let frameBytes = input.count & ~1
    var output = Data(capacity: frameBytes)
    var i = 0
    while i < frameBytes {
        output.append(input[i + 1])
        output.append(input[i])
        i += 2
    }
    return output
}

// MARK: - Big-endian helpers

private func beUInt32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].withUnsafeBytes {
        UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
    }
}

private func beUInt16(_ data: Data, at offset: Int) -> UInt16 {
    data[offset..<(offset + 2)].withUnsafeBytes {
        UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self))
    }
}

/// Parses the 80-bit extended-precision float used for the COMM sample rate.
private func parseExtended80(_ data: Data, at offset: Int) -> Double {
    let signAndExponent = beUInt16(data, at: offset)
    var mantissa: UInt64 = 0
    for i in 0..<8 {
        mantissa = (mantissa << 8) | UInt64(data[offset + 2 + i])
    }
    let exponent = Int(signAndExponent & 0x7FFF)
    if exponent == 0 && mantissa == 0 { return 0 }
    let sign: Double = (signAndExponent & 0x8000) != 0 ? -1 : 1
    return sign * Double(mantissa) * pow(2.0, Double(exponent - 16383 - 63))
}
