import AVFoundation
import Foundation

/// Offline acoustic echo cancellation: removes the speaker playback (system track) from the mic track.
/// Both tracks start at the same moment; ffmpeg decodes them to 48 kHz mono PCM, which runs through
/// WebRTC AEC3 (+ high-pass, low noise suppression) in 10 ms frames.
/// Output: lossless 16-bit PCM, 48 kHz mono; the container follows the extension (.caf or .wav).
/// On failure the partial output is removed.
enum EchoCanceller {
    static let rate = 48000
    static let noiseSuppression: Int32 = 1  // 0=off 1=low 2=moderate 3=high 4=very high
    static let outputExtensions: Set<String> = ["caf", "wav"]

    static func process(system: URL, mic: URL, output: URL, progress: ((Double) -> Void)? = nil) throws {
        guard outputExtensions.contains(output.pathExtension.lowercased()) else {
            throw CAError(what: "AEC output must be .caf or .wav: \(output.lastPathComponent)", status: -1)
        }
        do {
            try run(system: system, mic: mic, output: output, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func run(system: URL, mic: URL, output: URL, progress: ((Double) -> Void)?) throws {
        let expected = max(1, Finalizer.duration(mic) * Double(rate))
        let refStream = try PCMStream(url: system)
        let micStream = try PCMStream(url: mic)
        defer { refStream.close(); micStream.close() }

        guard let apm = wrtc_apm_create(Int32(rate), noiseSuppression) else {
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
            let nRef = refStream.read(into: &refChunk)
            let frames = (nMic + frame - 1) / frame
            // Zero-fill: reference ended early, or the last partial frame.
            for i in min(nRef, frames * frame)..<(frames * frame) { refChunk[i] = 0 }
            for i in nMic..<(frames * frame) { micChunk[i] = 0 }
            micChunk.withUnsafeMutableBufferPointer { m in
                refChunk.withUnsafeBufferPointer { r in
                    for f in 0..<frames {  // mic is processed in place
                        _ = wrtc_apm_process(apm, r.baseAddress! + f * frame, m.baseAddress! + f * frame)
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
    }
}

/// Streams an audio file as 48 kHz mono s16le, decoded by ffmpeg.
final class PCMStream {
    private let process = Process()
    private let handle: FileHandle
    private var pending = Data()
    private var eof = false

    init(url: URL) throws {
        guard let ffmpeg = Mixer.ffmpegPath() else { throw CAError(what: Mixer.ffmpegMissing, status: -1) }
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "error", "-i", url.path,
                             "-ac", "1", "-ar", String(EchoCanceller.rate), "-f", "s16le", "-"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try Subprocesses.run(process)
        handle = pipe.fileHandleForReading
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
