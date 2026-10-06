import XCTest

@testable import SpeechSynthesisHelperCore
@testable import speech_server

/// Integration tests for the persistent SSM helper: the real
/// `speech-synthesis-helper` binary (built alongside the test bundle) driven
/// over its stdin/stdout protocol, and the service-level fast path.
///
/// No model downloads — the helper uses the macOS system voice stack.
final class SSMHelperIntegrationTests: XCTestCase {
    /// The SPM build products directory containing the helper executable.
    private static var helperURL: URL {
        // The xctest bundle lives in the same products directory as the
        // package's executable products.
        Bundle(for: SSMHelperIntegrationTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("speech-synthesis-helper")
    }

    private func requireHelper() throws -> URL {
        let url = Self.helperURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("speech-synthesis-helper not built at \(url.path)")
        }
        return url
    }

    // MARK: - Raw protocol against the real helper

    /// Collects frames for a single synthesis request (until `.end`/`.error`).
    private func synthesizeOnce(
        stdin: FileHandle, frames: inout [HelperFrame], decoder: inout HelperFrameDecoder,
        stdout: FileHandle, text: String, deadline: TimeInterval = 20
    ) throws {
        try stdin.write(contentsOf: encodeRequest(HelperRequest(text: text)))
        let start = Date()
        while Date().timeIntervalSince(start) < deadline {
            let data = stdout.availableData
            if data.isEmpty { break }  // helper exited
            for frame in decoder.feed(data) {
                frames.append(frame)
                if frame == .end { return }
                if case .error = frame { return }
            }
        }
        XCTFail("no end frame within \(deadline)s; frames so far: \(frames)")
    }

    func testHelperSynthesizesAndStaysWarm() throws {
        let url = try requireHelper()
        let process = Process()
        process.executableURL = url
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        try process.run()
        defer {
            try? stdinPipe.fileHandleForWriting.close()
            process.waitUntilExit()
        }

        var decoder = HelperFrameDecoder()

        // Request 1 (cold channel).
        var first: [HelperFrame] = []
        try synthesizeOnce(
            stdin: stdinPipe.fileHandleForWriting, frames: &first, decoder: &decoder,
            stdout: stdoutPipe.fileHandleForReading, text: "Hello from the helper.")
        guard case .start(let rate, let channels)? = first.first else {
            return XCTFail("expected start frame first, got \(first)")
        }
        XCTAssertGreaterThan(rate, 0)
        XCTAssertEqual(channels, 1)
        let audioBytes = first.reduce(0) { count, frame in
            if case .audio(let pcm) = frame {
                XCTAssertEqual(pcm.count % 2, 0, "PCM chunks must be whole 16-bit frames")
                return count + pcm.count
            }
            return count
        }
        XCTAssertGreaterThan(audioBytes, 8_000, "expected a non-trivial amount of audio")
        XCTAssertEqual(first.last, .end)

        // Request 2 on the SAME process (warm channel must still work).
        var second: [HelperFrame] = []
        try synthesizeOnce(
            stdin: stdinPipe.fileHandleForWriting, frames: &second, decoder: &decoder,
            stdout: stdoutPipe.fileHandleForReading, text: "Still speaking.")
        XCTAssertEqual(second.last, .end)
        XCTAssertTrue(
            second.contains {
                if case .audio = $0 {
                    return true
                }
                else {
                    return false
                }
            },
            "second request on the same channel must produce audio")
    }

    func testHelperCancelStopsSynthesis() throws {
        let url = try requireHelper()
        let process = Process()
        process.executableURL = url
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        try process.run()
        defer {
            try? stdinPipe.fileHandleForWriting.close()
            process.waitUntilExit()
        }

        let longText = String(
            repeating: "This sentence is repeated many times to make a very long synthesis. ",
            count: 30)
        try stdinPipe.fileHandleForWriting.write(
            contentsOf: encodeRequest(HelperRequest(text: longText)))

        // Wait for the first audio frame, then cancel.
        var decoder = HelperFrameDecoder()
        var sawAudio = false
        var sawEnd = false
        let start = Date()
        while Date().timeIntervalSince(start) < 20 {
            let data = stdoutPipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            for frame in decoder.feed(data) {
                if case .audio = frame, !sawAudio {
                    sawAudio = true
                    try stdinPipe.fileHandleForWriting.write(
                        contentsOf: encodeRequest(HelperRequest(cancel: true)))
                }
                if frame == .end { sawEnd = true }
            }
            if sawEnd { break }
        }
        XCTAssertTrue(sawAudio, "expected audio before cancelling")
        XCTAssertTrue(sawEnd, "helper must send end after a cancelled synthesis")
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 15,
            "cancelled synthesis must wind down well before full render time")
    }

    func testHelperExitsOnStdinEOF() throws {
        let url = try requireHelper()
        let process = Process()
        process.executableURL = url
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = Pipe()
        try process.run()
        try stdinPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(process.isRunning, "helper must exit when its stdin closes")
    }

    // MARK: - Service-level fast path

    func testServiceUsesHelperForSystemVoice() async throws {
        let url = try requireHelper()
        var settings = SpeechSynthesisSettings()
        settings.helperPath = url.path
        let service = SpeechSynthesisTTSService(settings: settings)

        let data = try await service.synthesize(text: "Hello.", voice: "System Voice")
        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
        XCTAssertGreaterThan(data.count, 44)

        // Second request exercises the warm channel.
        let second = try await service.synthesize(text: "Hello again.", voice: "System Voice")
        XCTAssertGreaterThan(second.count, 44)
    }

    func testServiceFallsBackWhenHelperMissing() async throws {
        var settings = SpeechSynthesisSettings()
        settings.helperPath = "/nonexistent/speech-synthesis-helper"
        let service = SpeechSynthesisTTSService(settings: settings)

        // Must still synthesize (via `say`) despite the bogus helper path.
        let data = try await service.synthesize(text: "Hello.", voice: "System Voice")
        XCTAssertGreaterThan(data.count, 44)
    }

    func testServiceHelperDisabledByConfig() async throws {
        var settings = SpeechSynthesisSettings()
        settings.useHelper = false
        let service = SpeechSynthesisTTSService(settings: settings)
        let data = try await service.synthesize(text: "Hello.", voice: "System Voice")
        XCTAssertGreaterThan(data.count, 44)
    }
}
