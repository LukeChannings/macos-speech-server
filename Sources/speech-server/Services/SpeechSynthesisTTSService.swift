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
/// Streaming: `say` cannot write audio to a pipe (`-o` to a FIFO exits 0 but
/// produces zero bytes — the AudioFile API needs a seekable file), but it *does*
/// write its output file progressively as it synthesises (verified empirically:
/// first audio bytes land ~0.5–0.75 s in, then the file grows steadily). Each
/// synthesis therefore spawns one `say` process writing a WAV
/// (`--file-format=WAVE --data-format=LEI16@<rate>`, i.e. little-endian 16-bit
/// mono PCM at the configured sample rate — no resampling or byte-swapping
/// needed) and tails the growing file, yielding new PCM bytes as they appear.
/// Time-to-first-audio is sub-second instead of the full synthesis time, and
/// `say` handles sentence prosody across the whole input natively, so no
/// sentence splitting is needed. Output is `say`'s native level (no peak
/// normalisation) — exactly what `say` users hear.
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
        var pcm = Data()
        for try await chunk in synthesizeStream(text: text, voice: voice) {
            pcm.append(chunk)
        }
        guard !pcm.isEmpty else { throw SpeechSynthesisTTSError.noAudioProduced }
        logger.notice("SpeechSynthesis synthesize: \(pcm.count) PCM bytes → WAV")
        return makeWAV(pcmData: pcm, sampleRate: sampleRate)
    }

    func synthesizeStream(text: String, voice: String) -> AsyncThrowingStream<Data, Error> {
        let argumentResult = Result { try resolveVoiceArgument(voice) }
        logger.notice("SpeechSynthesis synthesizeStream: \(text.count) character(s)")

        return AsyncThrowingStream { continuation in
            let box = ProcessBox()
            let task = Task {
                do {
                    let argument = try argumentResult.get()
                    try await self.streamSay(
                        text: text, voiceArgument: argument, box: box, continuation: continuation)
                    continuation.finish()
                }
                catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                // A disconnecting consumer must kill `say` instead of leaking
                // a process that renders audio nobody will hear.
                task.cancel()
                box.terminate()
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

    // MARK: - Rendering (tail `say`'s growing WAV)

    /// Cap on how many bytes to scan for the `data` chunk before giving up.
    /// `say` places the payload at offset 4096 (page-aligned via a `FLLR`
    /// filler chunk); 64 KiB is a generous safety margin.
    private static let maxHeaderSearchBytes = 64 * 1024
    /// Maximum PCM bytes per yielded chunk (~0.74 s of audio at 22 050 Hz).
    private static let maxChunkBytes = 32 * 1024
    /// Tail poll interval.
    private static let pollNanoseconds: UInt64 = 50_000_000

    /// Spawns one `say` process for the whole text, writing little-endian
    /// 16-bit mono PCM WAV at `sampleRate`, and tails the growing file,
    /// yielding new payload bytes to `continuation` as they are synthesised.
    private func streamSay(
        text: String,
        voiceArgument: String?,
        box: ProcessBox,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let process = box.process
        process.executableURL = URL(fileURLWithPath: Self.sayPath)
        var arguments = [
            "--file-format=WAVE", "--data-format=LEI16@\(sampleRate)", "-o", url.path,
        ]
        if let voiceArgument { arguments.append(contentsOf: ["-v", voiceArgument]) }
        process.arguments = arguments

        // Text goes on stdin so arbitrary input (including leading dashes) is
        // never parsed as options.
        let stdin = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr

        try process.run()
        let stdinHandle = stdin.fileHandleForWriting
        stdinHandle.write(Data(text.utf8))
        try? stdinHandle.close()

        var header = Data()
        var payloadOffset: Int?
        var pending = Data()
        var fileHandle: FileHandle?
        defer { try? fileHandle?.close() }

        while true {
            // Capture liveness BEFORE reading: when `exited` is true, the
            // reads below happen after process exit and therefore see the
            // complete file.
            let exited = !process.isRunning

            if fileHandle == nil {
                // `say` creates the output file shortly after starting.
                fileHandle = try? FileHandle(forReadingFrom: url)
            }

            if let handle = fileHandle {
                while true {
                    let bytes = handle.readData(ofLength: 65_536)
                    if bytes.isEmpty { break }
                    if payloadOffset != nil {
                        pending.append(bytes)
                    }
                    else {
                        header.append(bytes)
                        if let offset = wavDataPayloadOffset(in: header) {
                            payloadOffset = offset
                            if header.count > offset {
                                pending.append(header.subdata(in: offset..<header.count))
                            }
                            header.removeAll(keepingCapacity: false)
                        }
                        else if header.count > Self.maxHeaderSearchBytes {
                            throw SpeechSynthesisTTSError.audioReadFailed
                        }
                    }
                }

                // Yield complete 16-bit frames in capped chunks; keep any odd
                // trailing byte pending until its other half arrives.
                while pending.count >= 2 {
                    let take = min(pending.count & ~1, Self.maxChunkBytes)
                    continuation.yield(Data(pending.prefix(take)))
                    pending.removeFirst(take)
                }
            }

            if exited || Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
        }

        // A cancelled consumer already got everything it wanted; don't
        // misreport the SIGTERM we sent as a synthesis failure.
        if Task.isCancelled { return }

        if process.terminationStatus != 0 {
            let message =
                String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SpeechSynthesisTTSError.sayFailed(
                status: Int(process.terminationStatus), message: message)
        }
    }

    /// Minimal `@unchecked Sendable` wrapper so the stream's `onTermination`
    /// closure can terminate the `say` process (`Process` itself is not
    /// `Sendable`).
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()

        func terminate() {
            if process.isRunning { process.terminate() }
        }
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
            return "Failed to parse the audio produced by `say`."
        }
    }
}
