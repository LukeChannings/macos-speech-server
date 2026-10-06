import XCTest
import Yams

@testable import speech_server

final class SpeechSynthesisConfigTests: XCTestCase {
    // MARK: - Engine parsing

    func testParseSpeechSynthesisEngine() throws {
        let yaml = "tts:\n  engine: speechsynthesis\n"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.engine, .speechSynthesis)
    }

    // MARK: - SpeechSynthesisSettings defaults

    func testSpeechSynthesisDefaultSettings() {
        let settings = SpeechSynthesisSettings()
        XCTAssertNil(settings.defaultVoice)
        XCTAssertEqual(settings.sampleRate, 22_050)
        XCTAssertTrue(settings.useHelper)
        XCTAssertNil(settings.helperPath)
    }

    func testHelperSettingsDefaultWhenAbsentFromYAML() throws {
        let yaml = """
            tts:
              engine: speechsynthesis
              speechsynthesis:
                sample_rate: 22050
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.speechSynthesis?.useHelper, true)
        XCTAssertNil(config.tts.speechSynthesis?.helperPath)
    }

    func testParseHelperSettings() throws {
        let yaml = """
            tts:
              engine: speechsynthesis
              speechsynthesis:
                use_helper: false
                helper_path: /opt/custom/speech-synthesis-helper
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.speechSynthesis?.useHelper, false)
        XCTAssertEqual(config.tts.speechSynthesis?.helperPath, "/opt/custom/speech-synthesis-helper")
    }

    func testDefaultConfigHasNoSpeechSynthesisBlock() {
        let config = ServerConfig()
        XCTAssertNil(config.tts.speechSynthesis)
    }

    // MARK: - SpeechSynthesisSettings YAML parsing

    func testParseSpeechSynthesisWithSystemVoiceIdentifier() throws {
        let yaml = """
            tts:
              engine: speechsynthesis
              speechsynthesis:
                default_voice: com.apple.siri.natural.en-GB-C
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.engine, .speechSynthesis)
        XCTAssertEqual(config.tts.speechSynthesis?.defaultVoice, "com.apple.siri.natural.en-GB-C")
    }

    func testParseSpeechSynthesisWithCustomSampleRate() throws {
        let yaml = """
            tts:
              engine: speechsynthesis
              speechsynthesis:
                sample_rate: 24000
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.speechSynthesis?.sampleRate, 24_000)
    }

    func testParseSpeechSynthesisWithBothFields() throws {
        let yaml = """
            tts:
              engine: speechsynthesis
              speechsynthesis:
                default_voice: Daniel
                sample_rate: 22050
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.speechSynthesis?.defaultVoice, "Daniel")
        XCTAssertEqual(config.tts.speechSynthesis?.sampleRate, 22_050)
    }

    func testMinimalSpeechSynthesisConfigUsesDefaults() throws {
        let yaml = "tts:\n  engine: speechsynthesis\n"
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        let settings = config.tts.speechSynthesis ?? SpeechSynthesisSettings()
        XCTAssertNil(settings.defaultVoice)
        XCTAssertEqual(settings.sampleRate, 22_050)
    }

    func testEmptySpeechSynthesisBlockUsesDefaults() throws {
        let yaml = """
            tts:
              engine: speechsynthesis
              speechsynthesis: {}
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        let settings = config.tts.speechSynthesis ?? SpeechSynthesisSettings()
        XCTAssertNil(settings.defaultVoice)
        XCTAssertEqual(settings.sampleRate, 22_050)
    }

    // MARK: - Coexistence with other engines

    func testOtherEnginesUnaffected() throws {
        let yaml = """
            tts:
              engine: avspeech
              avspeech:
                default_voice: Samantha
            """
        let config = try YAMLDecoder().decode(ServerConfig.self, from: yaml)
        XCTAssertEqual(config.tts.engine, .avspeech)
        XCTAssertEqual(config.tts.avspeech?.defaultVoice, "Samantha")
        XCTAssertNil(config.tts.speechSynthesis)
    }
}
