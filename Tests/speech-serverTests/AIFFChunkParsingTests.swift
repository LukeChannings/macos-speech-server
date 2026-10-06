import XCTest

@testable import SpeechSynthesisHelperCore

/// Tests for `aiffStreamInfo(in:)` — the pure AIFF chunk walker used by the
/// SSM helper to locate the SSND payload in a (possibly still-growing) AIFF
/// file written by the Speech Synthesis Manager.
final class AIFFChunkParsingTests: XCTestCase {
    // MARK: - Builders

    /// 80-bit extended float encoding of a sample rate (the AIFF COMM format).
    private func extended80(_ value: Double) -> Data {
        // Normalise: value = mantissa * 2^(exp - 16383 - 63) with top mantissa bit set.
        var exponent = 16383 + 63
        var v = value
        while v < 0x8000_0000_0000_0000 as Double {
            v *= 2
            exponent -= 1
        }
        let mantissa = UInt64(v)
        var data = Data()
        data.append(UInt8(exponent >> 8))
        data.append(UInt8(exponent & 0xFF))
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((mantissa >> UInt64(shift)) & 0xFF))
        }
        return data
    }

    private func beU32(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    private func beU16(_ v: UInt16) -> Data {
        var be = v.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    private func commBody(channels: Int = 1, rate: Double = 22_050, bits: Int = 16) -> Data {
        var body = Data()
        body.append(beU16(UInt16(channels)))
        body.append(beU32(0))  // numSampleFrames (unfinalised mid-write)
        body.append(beU16(UInt16(bits)))
        body.append(extended80(rate))
        return body
    }

    /// Builds FORM/<type> with the given chunks (id, body).
    private func aiff(formType: String = "AIFF", _ chunks: [(id: String, body: Data)]) -> Data {
        var data = Data()
        data.append(contentsOf: "FORM".utf8)
        data.append(beU32(0x7FFF_FFFF))  // unfinalised form size
        data.append(contentsOf: formType.utf8)
        for chunk in chunks {
            data.append(contentsOf: chunk.id.utf8)
            data.append(beU32(UInt32(chunk.body.count)))
            data.append(chunk.body)
            if chunk.body.count % 2 != 0 { data.append(0) }  // pad byte
        }
        return data
    }

    /// SSND body: offset + blockSize fields, then sound data.
    private func ssndBody(offset: UInt32 = 0, sound: Data = Data()) -> Data {
        var body = Data()
        body.append(beU32(offset))
        body.append(beU32(0))  // blockSize
        body.append(Data(repeating: 0, count: Int(offset)))
        body.append(sound)
        return body
    }

    // MARK: - Standard layout

    func testMinimalHeader() {
        let data = aiff([("COMM", commBody()), ("SSND", ssndBody())])
        let info = aiffStreamInfo(in: data)
        XCTAssertEqual(info?.sampleRate, 22_050)
        XCTAssertEqual(info?.channels, 1)
        XCTAssertEqual(info?.bitsPerSample, 16)
        // FORM header 12 + COMM (8+18) + SSND header 8 + offset/blockSize 8
        XCTAssertEqual(info?.payloadOffset, 12 + 26 + 8 + 8)
    }

    func testOtherRateAndChannels() {
        let data = aiff([("COMM", commBody(channels: 2, rate: 44_100)), ("SSND", ssndBody())])
        let info = aiffStreamInfo(in: data)
        XCTAssertEqual(info?.sampleRate, 44_100)
        XCTAssertEqual(info?.channels, 2)
    }

    func testSSNDOffsetFieldShiftsPayload() {
        let data = aiff([("COMM", commBody()), ("SSND", ssndBody(offset: 16))])
        XCTAssertEqual(aiffStreamInfo(in: data)?.payloadOffset, 12 + 26 + 8 + 8 + 16)
    }

    func testAIFCFormTypeAccepted() {
        let data = aiff(formType: "AIFC", [("COMM", commBody()), ("SSND", ssndBody())])
        XCTAssertNotNil(aiffStreamInfo(in: data))
    }

    // MARK: - Intermediate chunks (CoreAudio pads the header to 4096)

    func testFillerChunkBeforeSSND() {
        let filler = Data(repeating: 0, count: 4_000)
        let data = aiff([("COMM", commBody()), ("APPL", filler), ("SSND", ssndBody())])
        let info = aiffStreamInfo(in: data)
        XCTAssertEqual(info?.payloadOffset, 12 + 26 + (8 + 4_000) + 8 + 8)
    }

    func testOddSizedChunkIsPadded() {
        let odd = Data(repeating: 0xAB, count: 7)
        let data = aiff([("COMM", commBody()), ("junk", odd), ("SSND", ssndBody())])
        // aiff() appends the pad byte; the walker must skip it.
        XCTAssertEqual(aiffStreamInfo(in: data)?.payloadOffset, 12 + 26 + (8 + 8) + 8 + 8)
    }

    // MARK: - Incomplete headers return nil (caller waits for more bytes)

    func testEmptyReturnsNil() {
        XCTAssertNil(aiffStreamInfo(in: Data()))
    }

    func testTruncatedFormReturnsNil() {
        XCTAssertNil(aiffStreamInfo(in: Data("FOR".utf8)))
    }

    func testCOMMOnlyReturnsNil() {
        XCTAssertNil(aiffStreamInfo(in: aiff([("COMM", commBody())])))
    }

    func testSSNDHeaderIncompleteReturnsNil() {
        var data = aiff([("COMM", commBody())])
        data.append(contentsOf: "SSND".utf8)
        data.append(beU32(100))
        data.append(beU32(0))  // offset field present, blockSize missing
        XCTAssertNil(aiffStreamInfo(in: data))
    }

    func testSSNDWithoutCOMMReturnsNil() {
        XCTAssertNil(aiffStreamInfo(in: aiff([("SSND", ssndBody())])))
    }

    // MARK: - Invalid input

    func testNonFORMReturnsNil() {
        XCTAssertNil(aiffStreamInfo(in: Data(repeating: 0x42, count: 64)))
    }

    func testFORMButNotAIFFReturnsNil() {
        var data = Data()
        data.append(contentsOf: "FORM".utf8)
        data.append(beU32(100))
        data.append(contentsOf: "WAVE".utf8)
        data.append(Data(repeating: 0, count: 64))
        XCTAssertNil(aiffStreamInfo(in: data))
    }

    func testSliceWithNonZeroStartIndex() {
        let data = Data(repeating: 0xFF, count: 10) + aiff([("COMM", commBody()), ("SSND", ssndBody())])
        XCTAssertNotNil(aiffStreamInfo(in: data[10...]))
    }

    // MARK: - Byte swapping

    func testPCM16ByteSwap() {
        let be = Data([0x12, 0x34, 0xAB, 0xCD])
        XCTAssertEqual(pcm16BigEndianToLittleEndian(be), Data([0x34, 0x12, 0xCD, 0xAB]))
    }

    func testPCM16ByteSwapEmpty() {
        XCTAssertEqual(pcm16BigEndianToLittleEndian(Data()), Data())
    }
}
