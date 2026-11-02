import AVFoundation
import Foundation

/// Offline processing of the mic track with WebRTC AudioProcessing, in 10 ms frames:
/// echo cancellation (AEC3: removes the speaker playback, i.e. the system track, from the mic),
/// noise suppression and automatic level (AGC2 adaptive digital gain), plus a high-pass filter.
/// Tracks start at the same moment; ffmpeg decodes them to 48 kHz mono PCM.
/// Output: lossless 16-bit PCM, 48 kHz mono; the container follows the extension (.caf or .wav).
/// On failure the partial output is removed.
enum MicProcessor {
    static let rate = 48000
    static let outputExtensions: Set<String> = ["caf", "wav"]

    struct Options: Equatable {
        /// Echo cancellation; needs the system track.
        var echoCancellation = true
        var noiseSuppression = NoiseSuppression.low
        var autoLevel = false

        /// What runs, for session.json and the track's format note, e.g. "AEC3, noise suppression (low)".
        var summary: String {
            var steps: [String] = []
            if echoCancellation { steps.append("AEC3") }
            if noiseSuppression != .off { steps.append("noise suppression (\(noiseSuppression.rawValue))") }
            if autoLevel { steps.append("AGC2") }
            return steps.joined(separator: ", ")
        }
    }

    /// `system` is required with echo cancellation and ignored without it.
    static func process(system: URL?, mic: URL, output: URL, options: Options = Options(),
                        progress: ((Double) -> Void)? = nil) throws {
        guard outputExtensions.contains(output.pathExtension.lowercased()) else {
            throw CAError(what: "Mic processing output must be .caf or .wav: \(output.lastPathComponent)", status: -1)
        }
        guard !options.echoCancellation || system != nil else {
            throw CAError(what: "Echo cancellation needs the system track", status: -1)
        }
        do {
            try run(system: options.echoCancellation ? system : nil, mic: mic, output: output,
                    options: options, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func run(system: URL?, mic: URL, output: URL, options: Options,
                            progress: ((Double) -> Void)?) throws {
        let expected = max(1, Finalizer.duration(mic) * Double(rate))
        let refStream = try system.map(PCMStream.init(url:))
        defer { refStream?.close() }
        let micStream = try PCMStream(url: mic)
        defer { micStream.close() }

        guard let apm = wrtc_apm_create(Int32(rate), refStream != nil ? 1 : 0,
                                        Int32(options.noiseSuppression.webrtcLevel), options.autoLevel ? 1 : 0) else {
            throw CAError(what: "WebRTC APM init", status: -1)
        }
        defer { wrtc_apm_destroy(apm) }
        let frame = Int(wrtc_apm_frame_size(apm))

        // The APM works on Int16; write those samples as they are (no float round trip).
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatInt16, interleaved: false)
        let chunkFrames = frame * 100  // 1 s at a time
        let buf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(chunkFrames))!
        var micChunk = [Int16](repeating: 0, count: chunkFrames)
        var refChunk = [Int16](repeating: 0, count: chunkFrames)
        var total = 0

        while true {
            let nMic = micStream.read(into: &micChunk)
            if nMic == 0 { break }
            total += nMic
            let nRef = refStream?.read(into: &refChunk) ?? 0
            let frames = (nMic + frame - 1) / frame
            // Zero-fill: reference ended early, or the last partial frame.
            for i in min(nRef, frames * frame)..<(frames * frame) { refChunk[i] = 0 }
            for i in nMic..<(frames * frame) { micChunk[i] = 0 }
            micChunk.withUnsafeMutableBufferPointer { m in
                refChunk.withUnsafeBufferPointer { r in
                    for f in 0..<frames {  // mic is processed in place
                        _ = wrtc_apm_process(apm, refStream == nil ? nil : r.baseAddress! + f * frame,
                                             m.baseAddress! + f * frame)
                    }
                }
            }
            let out = buf.int16ChannelData![0]
            for i in 0..<nMic { out[i] = micChunk[i] }
            buf.frameLength = AVAudioFrameCount(nMic)
            try file.write(from: buf)
            progress?(Double(total) / expected)
        }
        if total == 0 { throw CAError(what: "could not decode \(mic.lastPathComponent)", status: -1) }
        // A decode error mid-file looks like the end of the stream: check how ffmpeg exited.
        try micStream.checkExit(mic)
        try refStream?.checkExit(system!)
    }
}

/// Streams an audio file as 48 kHz mono s16le, decoded by ffmpeg.
final class PCMStream {
    private let process = Process()
    private let handle: FileHandle
    private var pending = Data()
    private var eof = false
    /// ffmpeg's error output, drained on another thread so it can't fill up and block ffmpeg.
    /// Written before `errDone` is signalled, read only after waiting on it.
    private final class ErrorOutput: @unchecked Sendable { var data = Data() }
    private let errText = ErrorOutput()
    private let errDone = DispatchSemaphore(value: 0)

    init(url: URL) throws {
        guard let ffmpeg = Mixer.ffmpegPath() else { throw CAError(what: Mixer.ffmpegMissing, status: -1) }
        let pipe = Pipe(), errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-nostdin", "-v", "error", "-i", url.path,
                             "-ac", "1", "-ar", String(MicProcessor.rate), "-f", "s16le", "-"]
        process.standardOutput = pipe
        process.standardError = errPipe
        try Subprocesses.run(process)
        handle = pipe.fileHandleForReading
        let err = errText, done = errDone
        DispatchQueue.global(qos: .utility).async {
            err.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
    }

    /// After the stream was read to its end: throws if ffmpeg failed (e.g. a decode error part
    /// way through, which otherwise just looks like a shorter file). A stream closed before its
    /// end (the reference outlasting the mic) is not checked.
    func checkExit(_ url: URL) throws {
        guard eof else { return }
        process.waitUntilExit()
        errDone.wait()
        errDone.signal()  // close() may wait too
        guard process.terminationStatus != 0 else { return }
        let text = String(decoding: errText.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw CAError(what: "ffmpeg could not decode all of \(url.lastPathComponent): \(text)",
                      status: process.terminationStatus)
    }

    /// Fills up to `samples.count` samples; returns how many were read (0 = end).
    func read(into samples: inout [Int16]) -> Int {
        let want = samples.count * 2
        while pending.count < want && !eof {
            let d = handle.availableData
            if d.isEmpty { eof = true } else { pending.append(d) }
        }
        let n = min(want, pending.count) / 2
        pending.withUnsafeBytes { raw in
            samples.withUnsafeMutableBytes { dst in dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[0..<(n * 2)])) }
        }
        pending.removeFirst(n * 2)
        return n
    }

    func close() {
        // Close our end first: an ffmpeg blocked on a full pipe then fails its write and exits.
        // (Terminating it alone can hang: it tries to flush into the pipe nobody reads.)
        try? handle.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        Subprocesses.finished(process)
    }
}
