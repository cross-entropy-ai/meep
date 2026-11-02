import AVFoundation
import Foundation

/// One continuous capture file (16-bit PCM in CAF) on the session clock.
///
/// - Input buffers can arrive in any format (device changes mid-meeting switch sample rate /
///   channel count); they are converted to the fixed file format.
/// - Every buffer carries its capture host time. Whenever the file is behind the session clock
///   (capture restart, device swap, or a tap that delivers nothing during silence), the gap is
///   filled with silence, so sample N of every track is the same moment: no per-track offsets.
/// - PCM CAF needs no finalization pass: if the process dies, what was written stays readable.
///   (AAC in CAF does NOT survive a crash: it needs a packet table written at close. So capture
///   is PCM, and the Finalizer encodes to AAC after stop.)
final class TrackWriter {
    let url: URL
    let format: AVAudioFormat            // float32, non-interleaved, fixed rate/channels
    private var file: AVAudioFile?
    private let sessionStart: UInt64     // mach host time of session start
    private let queue: DispatchQueue
    private var converter: AVAudioConverter?

    private(set) var framesWritten: Int64 = 0
    /// Buffers actually captured (excludes padding). 0 = this track never recorded anything.
    private(set) var buffersCaptured = 0
    private(set) var peak: Float = 0
    private(set) var error: Error?

    init(url: URL, channels: AVAudioChannelCount, sessionStart: UInt64) throws {
        self.url = url
        self.sessionStart = sessionStart
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                               channels: channels, interleaved: false)!
        queue = DispatchQueue(label: "writer.\(url.lastPathComponent)")
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Converts `buffer` synchronously (so the caller's buffer can be reused right after),
    /// then pads + writes on the writer queue.
    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard buffer.frameLength > 0, let converted = convert(buffer) else { return }
        queue.async { [self] in
            guard file != nil else { return }
            peak = max(peak, converted.peakLevel())
            do {
                try padSilence(until: hostTime)
                try file?.write(from: converted)
                framesWritten += Int64(converted.frameLength)
                buffersCaptured += 1
            } catch {
                self.error = error
            }
        }
    }

    /// Pads up to `stopHost` and closes the file.
    func finish(at stopHost: UInt64) {
        queue.sync {
            try? padSilence(until: stopHost)
            file = nil
        }
    }

    // MARK: -

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inFmt = buffer.format
        if inFmt == format { return buffer.deepCopy() }
        if converter == nil || converter!.inputFormat != inFmt {
            converter = AVAudioConverter(from: inFmt, to: format)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / inFmt.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return (status == .error || out.frameLength == 0) ? nil : out
    }

    /// Writes zeros so that the file position matches the session clock at `host`.
    private func padSilence(until host: UInt64) throws {
        guard let file, host > sessionStart else { return }
        let expected = Int64((hostTimeToSeconds(host) - hostTimeToSeconds(sessionStart)) * format.sampleRate)
        var gap = expected - framesWritten
        guard gap > Int64(format.sampleRate * 0.05) else { return }  // ignore jitter < 50 ms
        let chunk: AVAudioFrameCount = 48000
        guard let zeros = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        for b in UnsafeMutableAudioBufferListPointer(zeros.mutableAudioBufferList) {
            if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) }
        }
        while gap > 0 {
            zeros.frameLength = AVAudioFrameCount(min(Int64(chunk), gap))
            try file.write(from: zeros)
            framesWritten += Int64(zeros.frameLength)
            gap -= Int64(zeros.frameLength)
        }
    }
}

extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        c.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(c.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            if let s = src[i].mData, let d = dst[i].mData {
                memcpy(d, s, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize)))
            }
        }
        return c
    }

    /// Max absolute sample value across channels (float formats only; 0 otherwise).
    func peakLevel() -> Float {
        guard let ch = floatChannelData else { return 0 }
        let n = Int(frameLength)
        let stride = format.isInterleaved ? Int(format.channelCount) : 1
        let planes = format.isInterleaved ? 1 : Int(format.channelCount)
        var p: Float = 0
        for c in 0..<planes {
            let data = ch[c]
            for i in 0..<(n * stride) { p = max(p, abs(data[i])) }
        }
        return p
    }
}
