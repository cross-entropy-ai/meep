import Foundation

/// Mixes system + mic tracks into one mono AAC file with ffmpeg.
/// Each track is first brought to the same loudness with a static gain, because the system
/// track is a full-scale digital signal while the mic picks up much quieter acoustic sound.
enum Mixer {
    static let targetLUFS = -20.0
    static let maxBoostDB = 20.0   // don't blow up the noise floor of a track that is mostly silent
    static let maxCutDB = -20.0

    struct Result { var gainsDB: [String: Double] = [:]; var loudnessLUFS: [String: Double] = [:] }

    static func ffmpegPath() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func mix(system: URL?, mic: URL?, output: URL) throws -> Result {
        var result = Result()
        var args = ["-y", "-hide_banner", "-loglevel", "error"]
        var chains: [String] = []
        var labels: [String] = []
        let inputs = [("system", system), ("mic", mic)].compactMap { name, u in u.map { (name, $0) } }
        for (i, (name, url)) in inputs.enumerated() {
            args += ["-i", url.path]
            var gain = 0.0
            if let lufs = try? loudness(of: url) {
                gain = min(max(targetLUFS - lufs, maxCutDB), maxBoostDB)
                result.loudnessLUFS[name] = lufs
            }
            result.gainsDB[name] = gain
            chains.append("[\(i):a]aformat=channel_layouts=mono,volume=\(String(format: "%.2f", gain))dB[a\(i)]")
            labels.append("[a\(i)]")
        }
        let filter = chains.joined(separator: ";") + ";" + labels.joined() +
            "amix=inputs=\(labels.count):duration=longest:normalize=0,alimiter=limit=0.95:level=false[out]"
        args += ["-filter_complex", filter, "-map", "[out]",
                 "-ar", "48000", "-ac", "1", "-c:a", "aac", "-b:a", "96k", output.path]
        _ = try runFFmpeg(args)
        return result
    }

    /// Integrated loudness (EBU R128, LUFS) of a file, mono-folded.
    static func loudness(of url: URL) throws -> Double {
        let err = try runFFmpeg(["-hide_banner", "-nostats", "-i", url.path,
                                 "-af", "aformat=channel_layouts=mono,ebur128=framelog=quiet", "-f", "null", "-"])
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

    /// Runs ffmpeg, returns stderr; throws on non-zero exit.
    private static func runFFmpeg(_ args: [String]) throws -> String {
        guard let ffmpeg = ffmpegPath() else {
            throw CAError(what: "ffmpeg not found (brew install ffmpeg)", status: -1)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: errData, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            throw CAError(what: "ffmpeg: " + text, status: p.terminationStatus)
        }
        return text
    }
}
