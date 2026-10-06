import ApplicationServices
import Foundation
import SpeechSynthesisHelperCore

// speech-synthesis-helper: persistent Carbon Speech Synthesis Manager renderer.
//
// Why this exists: each `say` invocation pays ~0.4 s of process + AudioFile
// setup plus a per-invocation voice warm-up (another ~0.2–0.7 s depending on
// the voice). The SSM speech channel kept alive in this process renders the
// same System Voice with first audio in tens of milliseconds (measured; see
// docs/plans/speechsynthesis-latency-floor.md). SSM synthesis only completes
// on a thread whose run loop is pumped — this helper pumps its main run loop,
// exactly the way `say` does, which a Vapor server never can.
//
// Protocol: length-prefixed JSON requests on stdin, typed frames on stdout
// (see SpeechSynthesisHelperCore/HelperProtocol.swift). One synthesis at a
// time; requests queue. Exits on stdin EOF or stdout EPIPE (parent gone).
//
// SSM cannot stream to a pipe (kSpeechOutputToFileDescriptorProperty accepts
// one but writes nothing and degrades to realtime — verified empirically), so
// each synthesis writes a temp AIFF via kSpeechOutputToFileURLProperty and
// tails it as it grows, byteswapping the big-endian samples to little-endian.

signal(SIGPIPE, SIG_IGN)

// MARK: - stdout framing (POSIX write; exit quietly when the parent is gone)

func emit(_ frame: HelperFrame) {
    let bytes = encodeFrame(frame)
    bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        var pointer = raw.baseAddress!
        var remaining = raw.count
        while remaining > 0 {
            let written = write(1, pointer, remaining)
            if written <= 0 { exit(0) }
            pointer += written
            remaining -= written
        }
    }
}

// MARK: - Inbox: requests parsed on a reader thread, consumed on main

final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var cancelFlag = false
    private var eofFlag = false

    func push(_ request: HelperRequest) {
        lock.lock()
        defer { lock.unlock() }
        if request.cancel == true { cancelFlag = true }
        if let text = request.text { texts.append(text) }
    }

    func markEOF() {
        lock.lock()
        defer { lock.unlock() }
        eofFlag = true
    }

    /// Pops the next queued text and clears any stale cancel flag (a cancel
    /// that raced with the completion of the previous synthesis must not
    /// cancel the next one).
    func popText() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !texts.isEmpty else { return nil }
        cancelFlag = false
        return texts.removeFirst()
    }

    func takeCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = cancelFlag
        cancelFlag = false
        return value
    }

    var isEOF: Bool {
        lock.lock()
        defer { lock.unlock() }
        return eofFlag && texts.isEmpty
    }
}

let inbox = Inbox()

let readerThread = Thread {
    var decoder = HelperRequestDecoder()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = read(0, &buffer, buffer.count)
        if count <= 0 {
            inbox.markEOF()
            return
        }
        for request in decoder.feed(Data(bytes: buffer, count: count)) {
            inbox.push(request)
        }
    }
}
readerThread.start()

// MARK: - Synthesis (main thread; pumps the run loop)

func pump(_ seconds: Double) {
    CFRunLoopRunInMode(CFRunLoopMode.defaultMode, seconds, false)
}

/// Renders `text` on `channel`, streaming frames to stdout. Returns `true`
/// when the channel was disposed to abort a cancelled synthesis — the caller
/// must create a fresh channel for the next request. (`StopSpeech` and
/// `StopSpeechAt(kImmediate)` return noErr but are ignored for render-to-file
/// synthesis; disposing the channel is the only way to abort — verified
/// empirically, see docs/plans/speechsynthesis-latency-floor.md.)
func performSynthesis(channel: SpeechChannel, text: String) -> Bool {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ssm-helper-" + UUID().uuidString + ".aiff")
    defer { try? FileManager.default.removeItem(at: url) }

    guard SetSpeechProperty(channel, kSpeechOutputToFileURLProperty, url as CFURL) == noErr else {
        emit(.error("SetSpeechProperty(kSpeechOutputToFileURLProperty) failed"))
        return false
    }
    guard SpeakCFString(channel, text as CFString, nil) == noErr else {
        emit(.error("SpeakCFString failed"))
        return false
    }

    let maxHeaderSearchBytes = 64 * 1024
    let maxChunkBytes = 32 * 1024
    var header = Data()
    var info: AIFFStreamInfo?
    var pending = Data()
    var fileHandle: FileHandle?
    var disposedChannel = false
    defer { try? fileHandle?.close() }

    while true {
        // Capture liveness BEFORE reading: when done, the reads below happen
        // after synthesis completed and therefore see the complete file.
        let done = SpeechBusy() == 0

        if fileHandle == nil {
            fileHandle = try? FileHandle(forReadingFrom: url)
        }

        if let handle = fileHandle {
            while true {
                let bytes = handle.readData(ofLength: 65_536)
                if bytes.isEmpty { break }
                if info != nil {
                    pending.append(bytes)
                }
                else {
                    header.append(bytes)
                    if let parsed = aiffStreamInfo(in: header) {
                        info = parsed
                        emit(.start(rate: parsed.sampleRate, channels: parsed.channels))
                        if header.count > parsed.payloadOffset {
                            pending.append(header.subdata(in: parsed.payloadOffset..<header.count))
                        }
                        header.removeAll(keepingCapacity: false)
                    }
                    else if header.count > maxHeaderSearchBytes {
                        emit(.error("no SSND chunk within \(maxHeaderSearchBytes) bytes"))
                        DisposeSpeechChannel(channel)
                        return true
                    }
                }
            }

            // Emit complete 16-bit frames (byteswapped BE→LE) in capped
            // chunks; keep any odd trailing byte pending.
            while pending.count >= 2 {
                let take = min(pending.count & ~1, maxChunkBytes)
                emit(.audio(pcm16BigEndianToLittleEndian(pending.prefix(take))))
                pending.removeFirst(take)
            }
        }

        if done { break }
        if !disposedChannel && inbox.takeCancel() {
            DisposeSpeechChannel(channel)
            disposedChannel = true
        }
        pump(0.01)
    }

    emit(.end)
    return disposedChannel
}

// MARK: - Channel management

func makeChannel() -> SpeechChannel? {
    var channel: SpeechChannel?
    guard NewSpeechChannel(nil, &channel) == noErr else { return nil }
    return channel
}

/// Pre-warms a channel: the first synthesis in a fresh process pays SSM/voice
/// session setup (~1 s measured); doing it on a throwaway utterance at
/// startup means the first real request is already warm.
func prewarm(_ channel: SpeechChannel) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ssm-helper-warmup-" + UUID().uuidString + ".aiff")
    defer { try? FileManager.default.removeItem(at: url) }
    guard SetSpeechProperty(channel, kSpeechOutputToFileURLProperty, url as CFURL) == noErr,
        SpeakCFString(channel, "Ready." as CFString, nil) == noErr
    else { return }
    while SpeechBusy() != 0 { pump(0.01) }
}

// MARK: - Main loop

var speechChannel = makeChannel()
guard speechChannel != nil else {
    emit(.error("NewSpeechChannel failed"))
    exit(1)
}
speechChannel.map(prewarm)

while !inbox.isEOF {
    if let text = inbox.popText() {
        if speechChannel == nil {
            speechChannel = makeChannel()
        }
        guard let channel = speechChannel else {
            // `.error` is terminal for the exchange; no `.end` follows.
            emit(.error("NewSpeechChannel failed"))
            continue
        }
        if performSynthesis(channel: channel, text: text) {
            speechChannel = nil  // disposed mid-render; recreate lazily
        }
    }
    else {
        pump(0.02)
    }
}
if let channel = speechChannel { DisposeSpeechChannel(channel) }
exit(0)
