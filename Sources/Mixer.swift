import Foundation
import Synchronization

/// Mixes system + mic tracks into one mono file with ffmpeg: AAC 96 kbps (.m4a), or 16-bit PCM
/// if the output ends in .wav or .caf. Inputs: what the bundled ffmpeg decodes (see
/// scripts/build-ffmpeg.sh).
/// Each track is first brought to the same loudness with a static gain, because the system
/// track is a full-scale digital signal while the mic picks up much quieter acoustic sound.
enum Mixer {
    static let targetLUFS = -20.0
    static let maxBoostDB = 20.0   // don't blow up the noise floor of a track that is mostly silent
    static let maxCutDB = -20.0
    static let outputExtensions: Set<String> = ["m4a", "wav", "caf"]

    struct Result { var gainsDB: [String: Double] = [:]; var loudnessLUFS: [String: Double] = [:] }

    /// The ffmpeg bundled at MeetingRecorder.app/Contents/Helpers/ffmpeg (built by scripts/build-ffmpeg.sh).
    /// Bundle.main is the .app also for the CLI (Contents/MacOS/MeetingRecorder run directly).
    /// MEETINGRECORDER_FFMPEG overrides it, for development.
    static func ffmpegPath() -> String? {
        let env = ProcessInfo.processInfo.environment["MEETINGRECORDER_FFMPEG"] ?? ""
        let path = if env.isEmpty {
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg").path
        } else {
            env
        }
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static let ffmpegMissing = "ffmpeg not found (MeetingRecorder.app/Contents/Helpers/ffmpeg, "
        + "or $MEETINGRECORDER_FFMPEG); rebuild the app with ./build.sh"

    static func mix(system: URL?, mic: URL?, output: URL, progress: ((Double) -> Void)? = nil) throws -> Result {
        var result = Result()
        var args = ["-y", "-hide_banner", "-loglevel", "error"]
        var chains: [String] = []
        var labels: [String] = []
        let inputs = [("system", system), ("mic", mic)].compactMap { name, u in u.map { (name, $0) } }
        // Progress: each loudness pass ~12%, the mix (decode + filter + AAC encode) the rest.
        let measureShare = 0.12, mixShare = 1 - measureShare * Double(inputs.count)
        for (i, (name, url)) in inputs.enumerated() {
            args += ["-i", url.path]
            var gain = 0.0
            let base = measureShare * Double(i)
            if let lufs = try? loudness(of: url, progress: { progress?(base + measureShare * $0) }) {
                gain = min(max(targetLUFS - lufs, maxCutDB), maxBoostDB)
                result.loudnessLUFS[name] = lufs
            }
            result.gainsDB[name] = gain
            chains.append("[\(i):a]aformat=channel_layouts=mono,volume=\(String(format: "%.2f", gain))dB[a\(i)]")
            labels.append("[a\(i)]")
        }
        let filter = chains.joined(separator: ";") + ";" + labels.joined() +
            "amix=inputs=\(labels.count):duration=longest:normalize=0,alimiter=limit=0.95:level=false[out]"
        let pcm = ["wav", "caf"].contains(output.pathExtension.lowercased())
        args += ["-filter_complex", filter, "-map", "[out]", "-ar", "48000", "-ac", "1"]
            + (pcm ? ["-c:a", "pcm_s16le"] : ["-c:a", "aac", "-b:a", "96k"])
        let length = inputs.map { Finalizer.duration($0.1) }.max() ?? 0
        let mixBase = 1 - mixShare
        let mixArgs = args
        try Finalizer.writeAtomically(to: output) { temp in
            _ = try runFFmpeg(mixArgs + [temp.path], duration: length, progress: { progress?(mixBase + mixShare * $0) })
        }
        progress?(1)
        return result
    }

    /// Integrated loudness (EBU R128, LUFS) of a file, mono-folded.
    private static func loudness(of url: URL, progress: @escaping (Double) -> Void) throws -> Double {
        let err = try runFFmpeg(["-hide_banner", "-nostats", "-i", url.path,
                                 "-af", "aformat=channel_layouts=mono,ebur128=framelog=quiet", "-f", "null", "-"],
                                duration: Finalizer.duration(url), progress: progress)
        // Summary block: "Integrated loudness:\n    I:         -14.2 LUFS"
        guard let summary = err.range(of: "Integrated loudness:"),
              let line = err[summary.upperBound...].split(separator: "\n").first(where: { $0.contains("I:") }),
              let value = Double(line.replacingOccurrences(of: "I:", with: "")
                                     .replacingOccurrences(of: "LUFS", with: "")
                                     .trimmingCharacters(in: .whitespaces)),
              value > -70 else {
            throw CAError(what: "loudness measurement", status: -1)
        }
        return value
    }

    /// Runs ffmpeg, returns stderr; throws on non-zero exit. With `progress` and the input
    /// `duration` (s), reports 0...1 from ffmpeg's `-progress` output (out_time_us).
    private static func runFFmpeg(_ args: [String], duration: Double,
                                  progress: ((Double) -> Void)?) throws -> String {
        guard let ffmpeg = ffmpegPath() else {
            throw CAError(what: ffmpegMissing, status: -1)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        let track = progress != nil && duration > 0
        p.arguments = ["-nostdin"] + (track ? ["-progress", "pipe:1"] : []) + args
        let errPipe = Pipe(), outPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = track ? outPipe : FileHandle.nullDevice
        try Subprocesses.run(p)
        defer { Subprocesses.finished(p) }
        // stderr is drained on another thread so neither pipe can fill up and block ffmpeg.
        let errData = Mutex(Data())
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            errData.withLock { $0 = data }
            errDone.signal()
        }
        if track {
            var buffer = Data()
            while case let chunk = outPipe.fileHandleForReading.availableData, !chunk.isEmpty {
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                        progress?(us / 1_000_000 / duration)
                    }
                }
            }
        }
        errDone.wait()
        p.waitUntilExit()
        let text = String(decoding: errData.withLock { $0 }, as: UTF8.self)
        if p.terminationStatus != 0 {
            throw CAError(what: "ffmpeg: " + text, status: p.terminationStatus)
        }
        return text
    }
}
