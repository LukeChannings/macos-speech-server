import Foundation

// MARK: - RIFF/WAVE chunk parsing

/// Package-internal. Locates the byte offset of the `data` chunk payload in a
/// RIFF/WAVE byte prefix, walking the chunk list from offset 12.
///
/// Returns `nil` when the prefix is too short to reach the `data` chunk header
/// (callers tailing a growing file should wait for more bytes) or when the
/// bytes are not a RIFF/WAVE stream at all. Handles non-standard intermediate
/// chunks such as the `FLLR` page-alignment filler that CoreAudio writes
/// (observed: `say` places the data payload at offset 4096, not 44), and the
/// one-byte pad after odd-sized chunks required by the RIFF spec.
func wavDataPayloadOffset(in bytes: Data) -> Int? {
    // Work on a re-based copy so integer offsets are valid regardless of the
    // slice the caller passed in.
    let data = Data(bytes)
    guard data.count >= 12,
        data[0..<4] == Data("RIFF".utf8),
        data[8..<12] == Data("WAVE".utf8)
    else { return nil }

    var pos = 12
    while pos + 8 <= data.count {
        let chunkID = data[pos..<(pos + 4)]
        let size = data[(pos + 4)..<(pos + 8)].withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
        if chunkID == Data("data".utf8) {
            return pos + 8
        }
        // Skip chunk body plus the pad byte after odd-sized chunks.
        let skip = Int(size) + (Int(size) & 1)
        pos += 8 + skip
    }
    return nil
}
