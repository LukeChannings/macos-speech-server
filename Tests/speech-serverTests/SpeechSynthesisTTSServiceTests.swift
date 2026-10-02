import XCTest

@testable import speech_server

/// Tests for SpeechSynthesisTTSService.
///
/// These exercise the real Carbon Speech Synthesis Manager (no model download —
/// the system voices ship with macOS). Unlike `AVSpeechSynthesizer`, this path is
/// not gated by the process code signature, so the full system voice set
/// (including the configured Siri "system" voice) is reachable even from the
/// ad-hoc-signed test binary.
final class SpeechSynthesisTTSServiceTests: XCTestCase {
    private var service: SpeechSynthesisTTSService!

    override func setUp() {
        super.setUp()
        service = SpeechSynthesisTTSService()
    }

    // MARK: - Voice enumeration

    func testAvailableVoicesNotEmpty() {
        XCTAssertFalse(service.availableVoices.isEmpty)
    }

    func testSystemVoiceIsAvailable() {
        XCTAssertTrue(
            service.availableVoices.contains("System Voice"),
            "The 'System Voice' option must always be available"
        )
    }

    func testDefaultVoiceIsSystemWhenUnconfigured() {
        XCTAssertEqual(service.defaultVoice, "System Voice")
    }

    func testLegacySystemAliasNormalisesToSystemVoice() {
        var settings = SpeechSynthesisSettings()
        settings.defaultVoice = "system"
        let svc = SpeechSynthesisTTSService(settings: settings)
        XCTAssertEqual(svc.defaultVoice, "System Voice")
    }

    func testDefaultVoiceInAvailableVoices() {
        XCTAssertTrue(service.availableVoices.contains(service.defaultVoice))
    }

    func testConfiguredDefaultVoiceIsAdvertised() {
        var settings = SpeechSynthesisSettings()
        settings.defaultVoice = "com.apple.siri.natural.en-GB-C"
        let svc = SpeechSynthesisTTSService(settings: settings)
        XCTAssertEqual(svc.defaultVoice, "com.apple.siri.natural.en-GB-C")
        XCTAssertTrue(
            svc.availableVoices.contains("com.apple.siri.natural.en-GB-C"),
            "A configured default voice must be advertised in availableVoices"
        )
    }

    // MARK: - Sample rate

    func testDefaultSampleRate() {
        XCTAssertEqual(service.sampleRate, 22_050)
    }

    func testCustomSampleRateFromSettings() {
        var settings = SpeechSynthesisSettings()
        settings.sampleRate = 24_000
        let svc = SpeechSynthesisTTSService(settings: settings)
        XCTAssertEqual(svc.sampleRate, 24_000)
    }

    // MARK: - synthesize

    func testSynthesizeSystemVoiceReturnsWAV() async throws {
        let data = try await service.synthesize(text: "Hello.", voice: "System Voice")
        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(data[8..<12], Data("WAVE".utf8))
        XCTAssertGreaterThan(data.count, 44)
    }

    func testSynthesizeLegacySystemAliasReturnsWAV() async throws {
        let data = try await service.synthesize(text: "Hello.", voice: "system")
        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
        XCTAssertGreaterThan(data.count, 44)
    }

    func testSynthesizeSampleRateInWAVHeader() async throws {
        let data = try await service.synthesize(text: "Hello.", voice: "System Voice")
        let rate = data[24..<28].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(Int(rate), service.sampleRate)
    }

    func testSynthesizeResampledRateInWAVHeader() async throws {
        var settings = SpeechSynthesisSettings()
        settings.sampleRate = 16_000
        let svc = SpeechSynthesisTTSService(settings: settings)
        let data = try await svc.synthesize(text: "Hello there.", voice: "System Voice")
        let rate = data[24..<28].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(Int(rate), 16_000)
        XCTAssertGreaterThan(data.count, 44)
    }

    func testSynthesizeInvalidVoiceThrows() async {
        do {
            _ = try await service.synthesize(text: "Hello.", voice: "this_is_not_a_real_voice_xyz")
            XCTFail("Expected voiceNotFound error")
        }
        catch let error as SpeechSynthesisTTSError {
            guard case .voiceNotFound = error else {
                return XCTFail("Unexpected SpeechSynthesisTTSError: \(error)")
            }
        }
        catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - synthesizeStream

    func testSynthesizeStreamYieldsAtLeastOneChunk() async throws {
        let stream = service.synthesizeStream(text: "Hello world.", voice: "System Voice")
        var chunks = 0
        for try await chunk in stream {
            XCTAssertFalse(chunk.isEmpty)
            chunks += 1
        }
        XCTAssertGreaterThan(chunks, 0)
    }

    func testSynthesizeStreamMultipleSentencesYieldMultipleChunks() async throws {
        let stream = service.synthesizeStream(
            text: "First sentence here. Second sentence here. Third one here.",
            voice: "System Voice"
        )
        var chunks = 0
        for try await chunk in stream {
            XCTAssertEqual(chunk.count % 2, 0, "16-bit PCM chunks must be even length")
            chunks += 1
        }
        XCTAssertGreaterThanOrEqual(chunks, 2, "Multiple sentences should stream as multiple chunks")
    }

    func testSynthesizeStreamInvalidVoiceThrows() async {
        let stream = service.synthesizeStream(text: "Hello.", voice: "this_is_not_a_real_voice_xyz")
        do {
            for try await _ in stream {}
            XCTFail("Expected voiceNotFound error")
        }
        catch let error as SpeechSynthesisTTSError {
            guard case .voiceNotFound = error else {
                return XCTFail("Unexpected SpeechSynthesisTTSError: \(error)")
            }
        }
        catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Classic voice by name

    func testSynthesizeClassicVoiceByName() async throws {
        // Enumeration must expose at least one classic voice name besides "System Voice".
        let classic = service.availableVoices.first { $0 != "System Voice" }
        guard let voice = classic else {
            throw XCTSkip("No classic voices enumerated")
        }
        let data = try await service.synthesize(text: "Hello.", voice: voice)
        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
        XCTAssertGreaterThan(data.count, 44)
    }
}
