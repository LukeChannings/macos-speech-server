import XCTest

@testable import SpeechSynthesisHelperCore

/// Tests for the SSM helper wire protocol: length-prefixed JSON requests
/// (service → helper stdin) and typed binary frames (helper stdout → service).
final class HelperProtocolTests: XCTestCase {
    // MARK: - Frames: round trips

    func testStartFrameRoundTrip() {
        let encoded = encodeFrame(.start(rate: 22_050, channels: 1))
        var decoder = HelperFrameDecoder()
        XCTAssertEqual(decoder.feed(encoded), [.start(rate: 22_050, channels: 1)])
    }

    func testAudioFrameRoundTrip() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        var decoder = HelperFrameDecoder()
        XCTAssertEqual(decoder.feed(encodeFrame(.audio(pcm))), [.audio(pcm)])
    }

    func testEndFrameRoundTrip() {
        var decoder = HelperFrameDecoder()
        XCTAssertEqual(decoder.feed(encodeFrame(.end)), [.end])
    }

    func testErrorFrameRoundTrip() {
        var decoder = HelperFrameDecoder()
        XCTAssertEqual(decoder.feed(encodeFrame(.error("boom"))), [.error("boom")])
    }

    // MARK: - Frames: streaming decode

    func testMultipleFramesInOneFeed() {
        var bytes = encodeFrame(.start(rate: 22_050, channels: 1))
        bytes.append(encodeFrame(.audio(Data([1, 2]))))
        bytes.append(encodeFrame(.end))
        var decoder = HelperFrameDecoder()
        let frames = decoder.feed(bytes)
        XCTAssertEqual(frames, [.start(rate: 22_050, channels: 1), .audio(Data([1, 2])), .end])
    }

    func testByteAtATimeFeed() {
        var bytes = encodeFrame(.audio(Data([9, 8, 7])))
        bytes.append(encodeFrame(.end))
        var decoder = HelperFrameDecoder()
        var frames: [HelperFrame] = []
        for byte in bytes {
            frames.append(contentsOf: decoder.feed(Data([byte])))
        }
        XCTAssertEqual(frames, [.audio(Data([9, 8, 7])), .end])
    }

    func testPartialFrameYieldsNothing() {
        let bytes = encodeFrame(.audio(Data(repeating: 7, count: 100)))
        var decoder = HelperFrameDecoder()
        XCTAssertEqual(decoder.feed(bytes.prefix(20)), [])
        XCTAssertEqual(decoder.feed(bytes.suffix(from: 20)), [.audio(Data(repeating: 7, count: 100))])
    }

    func testDecoderStateSurvivesAcrossFrames() {
        var decoder = HelperFrameDecoder()
        XCTAssertEqual(decoder.feed(encodeFrame(.end)), [.end])
        XCTAssertEqual(decoder.feed(encodeFrame(.end)), [.end])
    }

    // MARK: - Requests

    func testRequestRoundTrip() {
        let request = HelperRequest(text: "Hello world.")
        var decoder = HelperRequestDecoder()
        XCTAssertEqual(decoder.feed(encodeRequest(request)), [request])
    }

    func testCancelRequestRoundTrip() {
        let request = HelperRequest(cancel: true)
        var decoder = HelperRequestDecoder()
        let decoded = decoder.feed(encodeRequest(request))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.cancel, true)
        XCTAssertNil(decoded.first?.text)
    }

    func testRequestWithUnicodeText() {
        let request = HelperRequest(text: "Caffè — ünïcode ✓")
        var decoder = HelperRequestDecoder()
        XCTAssertEqual(decoder.feed(encodeRequest(request)), [request])
    }

    func testPartialRequestFeed() {
        let bytes = encodeRequest(HelperRequest(text: "split me"))
        var decoder = HelperRequestDecoder()
        XCTAssertEqual(decoder.feed(bytes.prefix(3)), [])
        XCTAssertEqual(decoder.feed(bytes.suffix(from: 3)), [HelperRequest(text: "split me")])
    }

    func testMultipleRequestsInOneFeed() {
        var bytes = encodeRequest(HelperRequest(text: "one"))
        bytes.append(encodeRequest(HelperRequest(cancel: true)))
        var decoder = HelperRequestDecoder()
        let decoded = decoder.feed(bytes)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].text, "one")
        XCTAssertEqual(decoded[1].cancel, true)
    }

    func testMalformedRequestJSONIsSkipped() {
        var bytes = Data()
        let garbage = Data("not json".utf8)
        var length = UInt32(garbage.count).littleEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(garbage)
        bytes.append(encodeRequest(HelperRequest(text: "after")))
        var decoder = HelperRequestDecoder()
        // Malformed entry is dropped; the stream stays in sync.
        XCTAssertEqual(decoder.feed(bytes), [HelperRequest(text: "after")])
    }
}
