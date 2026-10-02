import AVFoundation
import Foundation
import Logging

/// TTS service backed by the macOS `/usr/bin/say` command.
///
/// Why subprocess `say` rather than `AVSpeechSynthesizer` or the in-process Carbon
/// Speech Synthesis Manager:
///
///  - `AVSpeechSynthesizer` gates the premium / Siri voice tier on the calling
///    process's code signature, so an ad-hoc-signed binary (what `swift build` and
///    the Homebrew/Nix packages produce) only sees the low-quality compact voices
///    and can never reach the Siri "natural" voices.
///  - The in-process Carbon Speech Synthesis Manager is *not* gated by the signature
///    and reaches the full voice set, but its audio rendering is tied to the **main
///    run loop**: synthesis only completes on the process main thread. A Vapor server
///    never pumps a `CFRunLoop` on main, so in-process Carbon synthesis stalls.
///
/// `say` sidesteps both problems: it is Apple-provided, runs its own main-thread run
/// loop in its own process, is unaffected by *our* process's signature, and reaches
/// the full system voice set — including the voice configured under System Settings →
/// Accessibility → Spoken Content → System Voice (which can be a high-quality Siri
/// voice). It is literally the engine `say` users already hear.
///
/// Voice selection (`-v`):
///  - `"system"` (the default) → no `-v`, i.e. the OS-configured System Voice.
///  - a voice *name* from `say -v '?'` (e.g. `"Daniel (Enhanced)"`).
///  - a voice *identifier* (e.g. `"com.apple.siri.natural.en-GB-C"`); `say -v` accepts
///    identifiers as well as names.
///
/// Each synthesis spawns a short-lived `say` process writing an AIFF, which is then
/// read (and resampled if needed) into mono Float32. Processes run concurrently;
/// throughput is 2–5× realtime, so sentence-granularity streaming stays ahead of
/// playback.
final class SpeechSynthesisTTSService: TTSService, @unchecked Sendable {
    /// Friendly voice name mapping to the OS-configured System Voice (no `-v`).
    /// The legacy alias "system" is also accepted (see `isSystemVoice`).
    static let systemVoice = "System Voice"

    private static let sayPath = "/usr/bin/say"

    let sampleRate: Int
    let defaultVoice: String
    let availableVoices: [String]

    // Lowercased voice name -> canonical display name (for `-v`).
    private let voiceNames: [String: String]
    // Lowercased voice name -> BCP-47 language (e.g. "en-GB").
    private let voiceLanguages: [String: String]
    // Language of the configured System Voice (from Accessibility prefs), if known.
    private let systemVoiceLanguage: String?
    private let logger: Logger

    init(settings: SpeechSynthesisSettings = SpeechSynthesisSettings()) {
        self.sampleRate = settings.sampleRate

        let parsed = Self.enumerateVoices()
        var names: [String: String] = [:]
        var languages: [String: String] = [:]
        for voice in parsed {
            names[voice.name.lowercased()] = voice.name
            languages[voice.name.lowercased()] = voice.language
        }
        self.voiceNames = names
        self.voiceLanguages = languages

        // The "System Voice" option maps to the OS-configured System Voice (Settings →
        // Accessibility → Spoken Content → System Voice), typically a Siri "natural"
        // voice. Siri voices are not enumerated by `say -v '?'` nor any ad-hoc-reachable
        // API, so we expose this single friendly option (synthesised with no `-v`, i.e.
        // bare `say`) and read the Accessibility prefs only to report its language.
        self.systemVoiceLanguage =
            Self.configuredSystemVoiceIdentifiers()
            .lazy.compactMap { Self.localeCode(from: $0) }.first

        let configured = settings.defaultVoice
        let resolvedDefault =
            configured.map { Self.isSystemVoice($0) ? Self.systemVoice : $0 } ?? Self.systemVoice

        var advertised = Set(parsed.map { $0.name })
        advertised.insert(Self.systemVoice)
        advertised.insert(resolvedDefault)
        self.availableVoices = advertised.sorted()
        self.defaultVoice = resolvedDefault

        var l = Logger(label: "SpeechSynthesisTTSService")
        l.logLevel = .notice
        self.logger = l
    }

    // MARK: - TTSService

    func language(for voiceName: String) -> String {
        if Self.isSystemVoice(voiceName) { return systemVoiceLanguage ?? "en" }
        if let known = voiceLanguages[voiceName.lowercased()] { return known }
        return Self.localeCode(from: voiceName) ?? "en"
    }

    func synthesize(text: String, voice: String) async throws -> Data {
        let argument = try resolveVoiceArgument(voice)
        var all: [Float] = []
        for sentence in splitSentences(text) {
            all.append(contentsOf: try await renderSentence(sentence, voiceArgument: argument))
        }
        guard !all.isEmpty else { throw SpeechSynthesisTTSError.noAudioProduced }
        logger.notice("SpeechSynthesis synthesize: \(all.count) samples → WAV")
        return makeWAV(pcmData: float32ToPCM16(all), sampleRate: sampleRate)
    }

    func synthesizeStream(text: String, voice: String) -> AsyncThrowingStream<Data, Error> {
        let argumentResult = Result { try resolveVoiceArgument(voice) }
        let sentences = splitSentences(text)
        logger.notice("SpeechSynthesis synthesizeStream: \(sentences.count) sentence(s)")

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let argument = try argumentResult.get()
                    for sentence in sentences {
                        let samples = try await self.renderSentence(sentence, voiceArgument: argument)
                        if !samples.isEmpty {
                            continuation.yield(float32ToPCM16(samples))
                        }
                    }
                    continuation.finish()
                }
                catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Voice resolution

    /// Resolve a requested voice to the `-v` argument, or `nil` for the System Voice.
    /// Throws `.voiceNotFound` for an unrecognised name. Identifier-form voices
    /// (containing a ".") are passed through to `say` verbatim.
    private func resolveVoiceArgument(_ voice: String) throws -> String? {
        if Self.isSystemVoice(voice) {
            return nil
        }
        if let canonical = voiceNames[voice.lowercased()] {
            return canonical
        }
        if voice.contains(".") {
            return voice
        }
        throw SpeechSynthesisTTSError.voiceNotFound(voice)
    }

    /// Whether a voice string refers to the OS System Voice. Accepts the friendly
    /// name "System Voice" and the legacy alias "system" (both case-insensitive).
    private static func isSystemVoice(_ voice: String) -> Bool {
        let lower = voice.lowercased()
        return lower == systemVoice.lowercased() || lower == "system"
    }

    // MARK: - Rendering

    private func renderSentence(_ text: String, voiceArgument: String?) async throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        try await runSay(text: text, voiceArgument: voiceArgument, to: url)
        return try readResampledMono(url: url, targetRate: sampleRate)
    }

    /// Runs `say`, piping the text on stdin (so arbitrary text, including leading
    /// dashes, is never parsed as options) and writing an AIFF to `url`.
    private func runSay(text: String, voiceArgument: String?, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.sayPath)
            var arguments = ["-o", url.path]
            if let voiceArgument { arguments.append(contentsOf: ["-v", voiceArgument]) }
            process.arguments = arguments

            let stdin = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardError = stderr

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                }
                else {
                    let message =
                        String(
                            data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(
                        throwing: SpeechSynthesisTTSError.sayFailed(
                            status: Int(proc.terminationStatus), message: message))
                }
            }

            do {
                try process.run()
                let handle = stdin.fileHandleForWriting
                handle.write(Data(text.utf8))
                try? handle.close()
            }
            catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Reads an AIFF file into mono Float32 samples at `targetRate`, resampling if needed.
    private func readResampledMono(url: URL, targetRate: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
            let inBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount)
        else { return [] }
        try file.read(into: inBuffer)

        if srcFormat.sampleRate == Double(targetRate) && srcFormat.channelCount == 1 {
            return Self.floatSamples(inBuffer)
        }

        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(targetRate),
                channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: srcFormat, to: outFormat)
        else {
            throw SpeechSynthesisTTSError.audioReadFailed
        }

        let capacity =
            AVAudioFrameCount(Double(frameCount) * Double(targetRate) / srcFormat.sampleRate) + 2_048
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw SpeechSynthesisTTSError.audioReadFailed
        }

        var provided = false
        var convError: NSError?
        _ = converter.convert(to: outBuffer, error: &convError) { _, inStatus in
            if provided {
                inStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inStatus.pointee = .haveData
            return inBuffer
        }
        if let convError { throw convError }
        return Self.floatSamples(outBuffer)
    }

    private static func floatSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }

    /// The voice identifiers configured under System Settings → Accessibility →
    /// Spoken Content → System Voice (one per language). These are usually Siri
    /// voices that no ad-hoc-reachable enumeration API lists, so reading the
    /// preference is the only way to surface them as selectable options.
    private static func configuredSystemVoiceIdentifiers() -> [String] {
        guard
            let raw = UserDefaults(suiteName: "com.apple.Accessibility")?
                .array(forKey: "SpokenContentDefaultVoiceSelectionsByLanguage")
        else { return [] }
        var identifiers: [String] = []
        for element in raw {
            guard let selection = element as? [String: Any],
                let voiceId = selection["voiceId"] as? String, !voiceId.isEmpty
            else { continue }
            identifiers.append(voiceId)
        }
        return identifiers
    }

    // MARK: - Voice enumeration (`say -v '?'`)

    private static func enumerateVoices() -> [(name: String, language: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sayPath)
        process.arguments = ["-v", "?"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        }
        catch {
            return []
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var result: [(name: String, language: String)] = []
        for line in text.split(separator: "\n") {
            if let voice = parseVoiceLine(String(line)) {
                result.append(voice)
            }
        }
        return result
    }

    /// Parse one `say -v '?'` line: `<name>  <locale>  # <example>`.
    /// Names may contain spaces and parentheses (e.g. "Daniel (English (UK))"), so
    /// the locale is taken as the last whitespace token before the `#` comment.
    private static func parseVoiceLine(_ line: String) -> (name: String, language: String)? {
        let head =
            line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? line
        let tokens = head.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2 else { return nil }
        let locale = tokens[tokens.count - 1]
        let name = tokens[0..<(tokens.count - 1)].joined(separator: " ")
        guard !name.isEmpty, locale.contains("_") || locale.contains("-") else { return nil }
        let language = locale.replacingOccurrences(of: "_", with: "-")
        return (name, language)
    }

    /// Extract a BCP-47-ish locale (e.g. "en-GB") from a voice name/identifier.
    private static func localeCode(from string: String) -> String? {
        guard let range = string.range(of: "[a-z]{2}-[A-Z]{2}", options: .regularExpression)
        else { return nil }
        return String(string[range])
    }
}

// MARK: - Errors

enum SpeechSynthesisTTSError: Error, CustomStringConvertible {
    case voiceNotFound(String)
    case noAudioProduced
    case sayFailed(status: Int, message: String)
    case audioReadFailed

    var description: String {
        switch self {
        case .voiceNotFound(let voice):
            return
                "Voice '\(voice)' is not available. Use 'System Voice', a voice name from `say -v '?'` (e.g. 'Daniel (Enhanced)'), or a voice identifier (e.g. 'com.apple.siri.natural.en-GB-C')."
        case .noAudioProduced:
            return "`say` produced no audio for the given input."
        case .sayFailed(let status, let message):
            return "`say` failed (exit \(status))\(message.isEmpty ? "" : ": \(message)")."
        case .audioReadFailed:
            return "Failed to read or resample the audio produced by `say`."
        }
    }
}
