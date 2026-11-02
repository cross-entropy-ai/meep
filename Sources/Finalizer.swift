import AVFoundation
import Foundation

/// Turns a session's raw PCM capture into the final outputs. Used after a normal stop and to
/// finish sessions left behind by a crash (session.json status "recording").
///
///   raw/system.pcm.caf ─┬──────────────────────────────────┬─► mixed.m4a
///   raw/mic.pcm.caf ────┴─► [WebRTC AEC3] ─► raw/mic_aec.caf ┘
///   then raw/system.pcm.caf → raw/system.caf, raw/mic.pcm.caf → raw/mic.caf (AAC), PCM deleted.
enum Finalizer {
    static let systemPCM = "system.pcm.caf"
    static let micPCM = "mic.pcm.caf"
    static let rawFolder = "raw"

    /// Layout:  <session>/mixed.m4a  +  <session>/raw/{system,mic,mic_aec}.caf, session.json
    static func rawDir(_ dir: URL) -> URL { dir.appendingPathComponent(rawFolder, isDirectory: true) }

    /// Processes `dir`, merges results into `meta`, writes session.json. Returns warnings.
    @discardableResult
    /// `captured`: whether each track actually recorded audio (nil = unknown, e.g. crash recovery:
    /// then any non-empty file counts).
    static func finalize(dir: URL, meta inMeta: [String: Any], echoMode: EchoMode,
                         captured: (system: Bool, mic: Bool)? = nil) -> [String] {
        var meta = inMeta
        var warnings = (meta["warnings"] as? [String]) ?? []
        let raw = rawDir(dir)
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let f = { (name: String) in raw.appendingPathComponent(name) }
        let sysPCM = f(systemPCM), micPCM = f(micPCM)
        let hasSys = captured?.system ?? hasAudio(sysPCM)
        let hasMic = captured?.mic ?? hasAudio(micPCM)

        // 1. Echo cancellation on the lossless capture.
        var aec = false
        if echoMode == .webrtc && hasSys && hasMic {
            do {
                try EchoCanceller.process(system: sysPCM, mic: micPCM, output: f("mic_aec.caf"))
                aec = true
            } catch {
                warnings.append(tr("Echo cancellation failed (the mix uses the raw mic track): ", "回声消除失败（混音改用原始麦克风轨）: ") + "\(error)")
            }
        }

        // 2. Loudness-matched mix.
        var mixInfo = Mixer.Result()
        var mixed = false
        if hasSys || hasMic {
            do {
                mixInfo = try Mixer.mix(system: hasSys ? sysPCM : nil,
                                        mic: hasMic ? (aec ? f("mic_aec.caf") : micPCM) : nil,
                                        output: dir.appendingPathComponent("mixed.m4a"))
                mixed = true
            } catch {
                warnings.append(tr("Mixing failed (the tracks are kept): ", "混音失败（分轨文件仍在）: ") + "\(error)")
            }
        }

        // 3. Encode tracks to AAC; drop the PCM only when the AAC file checks out.
        var tracks = (meta["tracks"] as? [String: [String: Any]]) ?? [:]
        for (key, pcm, out, bitRate, has) in [("system", sysPCM, f("system.caf"), 128_000, hasSys),
                                              ("mic", micPCM, f("mic.caf"), 64_000, hasMic)] {
            var t = tracks[key] ?? [:]
            t["duration_sec"] = duration(pcm)
            if !FileManager.default.fileExists(atPath: pcm.path), FileManager.default.fileExists(atPath: out.path) {
                t["file"] = "\(rawFolder)/\(out.lastPathComponent)"  // encoded before a crash
                tracks[key] = t
                continue
            }
            // Never discard captured data on a heuristic: anything on disk gets encoded.
            guard has || duration(pcm) > 0 else {
                t["file"] = NSNull()
                try? FileManager.default.removeItem(at: pcm)
                tracks[key] = t
                continue
            }
            if !has { t["note"] = "no audio was captured on this track (silence only)" }
            do {
                try encodeAAC(pcm, to: out, bitRate: bitRate)
                t["file"] = "\(rawFolder)/\(out.lastPathComponent)"
                t["format"] = "AAC 48kHz \(key == "system" ? "stereo" : "mono") \(bitRate / 1000)kbps"
                try? FileManager.default.removeItem(at: pcm)
            } catch {
                t["file"] = "\(rawFolder)/\(pcm.lastPathComponent)"  // keep the lossless capture
                t["format"] = "PCM 16-bit 48kHz"
                warnings.append(tr("\(key): AAC encoding failed, kept the PCM file: ", "\(key) 转 AAC 失败，保留了 PCM 文件: ") + "\(error)")
            }
            tracks[key] = t
        }
        tracks["mic_aec"] = ["file": aec ? "\(rawFolder)/mic_aec.caf" : NSNull(),
                             "format": "AAC 48kHz mono 64kbps, WebRTC AEC3"]

        meta["tracks"] = tracks
        meta["mixed"] = mixed ? "mixed.m4a" : NSNull()
        meta["mix_loudness_lufs"] = mixInfo.loudnessLUFS
        meta["mix_gain_db"] = mixInfo.gainsDB
        meta["warnings"] = warnings
        writeMeta(meta, to: dir)
        return warnings
    }

    /// Finds sessions whose capture never finished (crash, force quit) and finalizes them.
    /// Returns the directories it processed.
    static func recoverUnfinished(root: URL) -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var done: [URL] = []
        for dir in dirs {
            guard var meta = readMeta(dir), ["recording", "saving"].contains(meta["status"] as? String ?? "") else { continue }
            // Skip a capture whose recording process is still alive (e.g. another running instance).
            if let pid = meta["pid"] as? Int32, pid != getpid(), kill(pid, 0) == 0 { continue }
            let mode = (meta["echo_cancellation"] as? String).flatMap(EchoMode.init(rawValue:)) ?? .off
            let raw = rawDir(dir)
            let dur = max(duration(raw.appendingPathComponent(systemPCM)), duration(raw.appendingPathComponent(micPCM)))
            meta["status"] = "recovered_after_crash"
            meta["duration_sec"] = dur
            var w = (meta["warnings"] as? [String]) ?? []
            w.append(tr("The app quit unexpectedly while recording; recovered about \(Int(dur)) s from the capture files.", "录制进程意外退出；已从临时文件恢复（约 \(Int(dur)) 秒）。"))
            meta["warnings"] = w
            finalize(dir: dir, meta: meta, echoMode: mode)
            done.append(dir)
        }
        return done
    }

    // MARK: - Helpers

    static func readMeta(_ dir: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: rawDir(dir).appendingPathComponent("session.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func writeMeta(_ meta: [String: Any], to dir: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        else { return }
        let raw = rawDir(dir)
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        try? data.write(to: raw.appendingPathComponent("session.json"), options: .atomic)
    }

    private static func hasAudio(_ url: URL) -> Bool {
        duration(url) > 0
    }

    static func duration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// PCM CAF → AAC CAF with the system encoder (afconvert ships with macOS).
    private static func encodeAAC(_ input: URL, to output: URL, bitRate: Int) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "caff", "-d", "aac", "-b", String(bitRate), input.path, output.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CAError(what: "afconvert: \(msg)", status: p.terminationStatus) }
        // Sanity check: encoded length must match the capture (within AAC frame granularity).
        let a = duration(input), b = duration(output)
        guard abs(a - b) < 0.1 else {
            throw CAError(what: "AAC duration \(b)s != PCM \(a)s", status: -1)
        }
    }
}
