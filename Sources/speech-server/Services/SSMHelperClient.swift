import Foundation
import Logging
import SpeechSynthesisHelperCore

/// Client for the persistent `speech-synthesis-helper` process.
///
/// The helper keeps a long-lived Carbon SSM speech channel so the System
/// Voice model stays loaded across requests, cutting warm time-to-first-audio
/// from ~1 s (`say` spawn + per-invocation voice warm-up) to tens of
/// milliseconds. One synthesis is in flight at a time; a second concurrent
/// request reports `.unavailable` so the caller can fall back to the `say`
/// path (preserving the old engine's request parallelism).
///
/// Failure philosophy: the helper is an optimisation, never a requirement.
/// Anything unexpected — missing binary, crash, sample-rate mismatch, decode
/// trouble — resolves to `.unavailable` (when no audio has been yielded yet)
/// so the caller silently falls back to `say`. `.failed` is only reported
/// when audio was already delivered, because the caller can no longer restart
/// the synthesis cleanly.
actor SSMHelperClient {
    enum Outcome {
        case completed
        case unavailable
        case failed(any Error)
    }

    private let helperURL: URL
    private let logger: Logger

    private var process: Process?
    private var requestHandle: FileHandle?
    private var consumeTask: Task<Void, Never>?
    // Frames buffered by the stdout-consuming task, popped by `nextFrame()`.
    // `generation` guards against a stale consumer polluting a fresh spawn.
    private var frameBuffer: [HelperFrame] = []
    private var frameWaiter: CheckedContinuation<HelperFrame?, Never>?
    private var streamEnded = true
    private var generation = 0
    private var busy = false
    private var unusable = false
    /// Frames from a cancelled synthesis still owed by the helper; they must
    /// be consumed before the next request is sent.
    private var needsDrain = false

    init(helperURL: URL) {
        self.helperURL = helperURL
        var logger = Logger(label: "SSMHelperClient")
        logger.logLevel = .notice
        self.logger = logger
    }

    /// Spawns the helper (which pre-warms its speech channel on startup) so
    /// the first real request doesn't pay process spawn + SSM session setup.
    func prewarm() {
        _ = ensureProcess()
    }

    /// Runs one synthesis through the helper, delivering little-endian 16-bit
    /// mono PCM chunks via `yield`. Cooperative cancellation of the calling
    /// task sends a cancel request to the helper (which stops the in-flight
    /// SSM synthesis without killing the process).
    func run(text: String, expectedRate: Int, yield: @escaping @Sendable (Data) -> Void) async -> Outcome {
        guard !unusable, !busy else { return .unavailable }
        busy = true
        defer { busy = false }

        guard ensureProcess() else { return .unavailable }
        if needsDrain {
            guard await drainStaleFrames() else { return .unavailable }
        }

        guard send(HelperRequest(text: text)) else {
            teardown()
            return .unavailable
        }

        let cancelHandle = requestHandle
        var yieldedAudio = false

        return await withTaskCancellationHandler {
            while let frame = await nextFrame() {
                if Task.isCancelled {
                    // The cancellation handler already asked the helper to
                    // stop; remaining frames are drained before the next use.
                    needsDrain = true
                    return .completed
                }
                switch frame {
                case .start(let rate, let channels):
                    if rate != expectedRate || channels != 1 {
                        logger.notice(
                            "SSM helper output \(rate) Hz/\(channels)ch but \(expectedRate) Hz mono is configured; disabling helper (say resamples natively)"
                        )
                        unusable = true
                        _ = send(HelperRequest(cancel: true))
                        needsDrain = true
                        _ = await drainStaleFrames()
                        return .unavailable
                    }
                case .audio(let pcm):
                    yield(pcm)
                    yieldedAudio = true
                case .end:
                    return .completed
                case .error(let message):
                    logger.warning("SSM helper error: \(message)")
                    return yieldedAudio
                        ? .failed(SpeechSynthesisTTSError.helperFailed(message))
                        : .unavailable
                }
            }
            // Frame stream ended: either the consumer task was cancelled
            // (AsyncStream finishes early on cancellation) or the helper died.
            if Task.isCancelled {
                needsDrain = true
                return .completed
            }
            logger.warning("SSM helper process exited unexpectedly")
            teardown()
            return yieldedAudio
                ? .failed(SpeechSynthesisTTSError.helperFailed("helper process exited mid-synthesis"))
                : .unavailable
        } onCancel: {
            if let handle = cancelHandle {
                try? handle.write(contentsOf: encodeRequest(HelperRequest(cancel: true)))
            }
        }
    }

    // MARK: - Process lifecycle

    private func ensureProcess() -> Bool {
        if let process, process.isRunning { return true }
        teardown()

        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            logger.notice(
                "speech-synthesis-helper not found at \(helperURL.path); using `say` for all synthesis")
            unusable = true
            return false
        }

        let process = Process()
        process.executableURL = helperURL
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        do {
            try process.run()
        }
        catch {
            logger.warning("failed to launch speech-synthesis-helper: \(error); using `say`")
            unusable = true
            return false
        }

        self.process = process
        self.requestHandle = stdinPipe.fileHandleForWriting

        let readHandle = stdoutPipe.fileHandleForReading
        let stream = AsyncStream<HelperFrame> { continuation in
            let thread = Thread {
                var decoder = HelperFrameDecoder()
                while true {
                    let data = readHandle.availableData
                    if data.isEmpty { break }
                    for frame in decoder.feed(data) {
                        continuation.yield(frame)
                    }
                }
                continuation.finish()
            }
            thread.name = "ssm-helper-stdout"
            thread.start()
        }

        generation += 1
        let currentGeneration = generation
        frameBuffer.removeAll()
        streamEnded = false
        needsDrain = false
        consumeTask = Task { [weak self] in
            for await frame in stream {
                await self?.deliver(frame, generation: currentGeneration)
            }
            await self?.deliverEnd(generation: currentGeneration)
        }
        logger.notice("speech-synthesis-helper started (pid \(process.processIdentifier))")
        return true
    }

    private func teardown() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        requestHandle = nil
        consumeTask?.cancel()
        consumeTask = nil
        generation += 1  // invalidate any in-flight deliveries
        frameBuffer.removeAll()
        streamEnded = true
        needsDrain = false
        frameWaiter?.resume(returning: nil)
        frameWaiter = nil
    }

    private func deliver(_ frame: HelperFrame, generation: Int) {
        guard generation == self.generation else { return }
        if let waiter = frameWaiter {
            frameWaiter = nil
            waiter.resume(returning: frame)
        }
        else {
            frameBuffer.append(frame)
        }
    }

    private func deliverEnd(generation: Int) {
        guard generation == self.generation else { return }
        streamEnded = true
        if let waiter = frameWaiter {
            frameWaiter = nil
            waiter.resume(returning: nil)
        }
    }

    private func send(_ request: HelperRequest) -> Bool {
        guard let requestHandle else { return false }
        do {
            try requestHandle.write(contentsOf: encodeRequest(request))
            return true
        }
        catch {
            return false
        }
    }

    private func nextFrame() async -> HelperFrame? {
        if !frameBuffer.isEmpty {
            return frameBuffer.removeFirst()
        }
        if streamEnded { return nil }
        return await withCheckedContinuation { continuation in
            frameWaiter = continuation
        }
    }

    /// Consumes leftover frames from a cancelled synthesis until its `end`
    /// (or `error`) marker. A watchdog kills the helper if it fails to wind
    /// down within 3 seconds; the next request respawns it.
    private func drainStaleFrames() async -> Bool {
        let box = TerminableProcess(process)
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // A cancelled sleep returns immediately; terminating here would
            // kill a healthy helper right after a successful drain.
            guard !Task.isCancelled else { return }
            box.terminate()
        }
        defer { watchdog.cancel() }

        while let frame = await nextFrame() {
            switch frame {
            case .end, .error:
                needsDrain = false
                return true
            case .start, .audio:
                continue
            }
        }
        logger.warning("SSM helper did not wind down after cancel; restarting it")
        teardown()
        return false
    }

    /// `Process` is not `Sendable`; this box lets the drain watchdog
    /// terminate it from a detached task.
    private final class TerminableProcess: @unchecked Sendable {
        private let process: Process?
        init(_ process: Process?) { self.process = process }
        func terminate() {
            if let process, process.isRunning { process.terminate() }
        }
    }
}
