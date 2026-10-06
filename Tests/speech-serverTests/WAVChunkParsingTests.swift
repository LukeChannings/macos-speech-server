import XCTest

@testable import speech_server

/// Tests for `wavDataPayloadOffset(in:)` — the pure RIFF chunk walker used to
/// locate the start of the `data` chunk payload in a (possibly still-growing)
/// WAV file written by `say`.
final class WAVChunkParsingTests: XCTestCase {
    // MARK: - Helpers

    /// Builds a RIFF/WAVE header with the given chunks appended after "WAVE".
    /// Each chunk is (id, body).
    private func riff(_ chunks: [(id: String, body: Data)]) -> Data {
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        var fileSize = UInt32(0x7FFF_FFFF).littleEndian
        withUnsafeBytes(of: &fileSize) { data.append(contentsOf: $0) }
        data.append(contentsOf: "WAVE".utf8)
        for chunk in chunks {
            data.append(contentsOf: chunk.id.utf8)
            var size = UInt32(chunk.body.count).littleEndian
            withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
            data.append(chunk.body)
        }
        return data
    }

    private var fmtBody: Data {
        // 16-byte PCM fmt chunk: format 1, mono, 22050 Hz, 16-bit.
        var body = Data()
        func u16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { body.append(contentsOf: $0) }
        }
        func u32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { body.append(contentsOf: $0) }
        }
        u16(1)
        u16(1)
        u32(22_050)
        u32(44_100)
        u16(2)
        u16(16)
        return body
    }

    // MARK: - Standard layout (data at offset 44)

    func testStandardHeaderFromMakeWAV() {
        let wav = makeWAV(pcmData: Data([1, 2, 3, 4]), sampleRate: 22_050)
        XCTAssertEqual(wavDataPayloadOffset(in: wav), 44)
    }

    func testStandardHeaderWithoutPayloadBytes() {
        // Header complete through the data chunk header, zero payload bytes yet.
        let wav = riff([("fmt ", fmtBody), ("data", Data())])
        XCTAssertEqual(wavDataPayloadOffset(in: wav), 44)
    }

    // MARK: - FLLR padding layout (what `say` writes: data payload at 4096)

    func testFLLRPaddedHeader() {
        let filler = Data(repeating: 0, count: 4_044)
        let wav = riff([("fmt ", fmtBody), ("FLLR", filler), ("data", Data())])
        XCTAssertEqual(wavDataPayloadOffset(in: wav), 4_096)
    }

    func testFLLRPaddedHeaderWithPayload() {
        let filler = Data(repeating: 0, count: 4_044)
        let wav = riff([("fmt ", fmtBody), ("FLLR", filler), ("data", Data(repeating: 7, count: 100))])
        XCTAssertEqual(wavDataPayloadOffset(in: wav), 4_096)
    }

    // MARK: - Odd-sized chunk padding

    func testOddSizedChunkIsPaddedToEvenBoundary() {
        // RIFF chunks with odd sizes are padded with one byte; the walker must
        // account for the pad when skipping.
        var oddChunk = Data(repeating: 0xAB, count: 7)
        oddChunk.append(0)  // pad byte
        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        var fileSize = UInt32(0x7FFF_FFFF).littleEndian
        withUnsafeBytes(of: &fileSize) { wav.append(contentsOf: $0) }
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "junk".utf8)
        var size = UInt32(7).littleEndian
        withUnsafeBytes(of: &size) { wav.append(contentsOf: $0) }
        wav.append(oddChunk)
        wav.append(contentsOf: "data".utf8)
        var dataSize = UInt32(0).littleEndian
        withUnsafeBytes(of: &dataSize) { wav.append(contentsOf: $0) }
        XCTAssertEqual(wavDataPayloadOffset(in: wav), 12 + 8 + 8 + 8)
    }

    // MARK: - Incomplete headers return nil (caller should wait for more bytes)

    func testEmptyDataReturnsNil() {
        XCTAssertNil(wavDataPayloadOffset(in: Data()))
    }

    func testTruncatedRIFFMagicReturnsNil() {
        XCTAssertNil(wavDataPayloadOffset(in: Data("RIF".utf8)))
    }

    func testHeaderEndingMidChunkHeaderReturnsNil() {
        // fmt chunk complete, then only 3 bytes of the next chunk id.
        var wav = riff([("fmt ", fmtBody)])
        wav.append(contentsOf: "dat".utf8)
        XCTAssertNil(wavDataPayloadOffset(in: wav))
    }

    func testHeaderEndingBeforeDataChunkReturnsNil() {
        let wav = riff([("fmt ", fmtBody)])
        XCTAssertNil(wavDataPayloadOffset(in: wav))
    }

    // MARK: - Invalid input returns nil

    func testNonRIFFDataReturnsNil() {
        XCTAssertNil(wavDataPayloadOffset(in: Data(repeating: 0x42, count: 64)))
    }

    func testRIFFButNotWAVEReturnsNil() {
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        var size = UInt32(100).littleEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(contentsOf: "AVI ".utf8)
        data.append(Data(repeating: 0, count: 64))
        XCTAssertNil(wavDataPayloadOffset(in: data))
    }
}
