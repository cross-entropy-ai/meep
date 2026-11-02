import AVFoundation
import Foundation

/// Turns a session's raw PCM capture into the final outputs. Used after a normal stop and to
/// finish sessions left behind by a crash or a quit during processing (session.json status
/// "recording" or "saving").
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

    /// Relative cost of each step, measured on 10 min of audio (M-series Mac); all scale with length.
    private enum Cost {
        static let aec = 11.6, mix = 5.0, encodeSystem = 2.5, encodeMic = 1.5
    }

    /// Processes `dir`, merges results into `meta`, writes session.json. Returns warnings.
    /// `captured`: whether each track actually recorded audio (nil = unknown, e.g. crash recovery:
    /// then any non-empty file counts). `progress` gets 0...1, from the calling thread.
    @discardableResult
    static func finalize(dir: URL, meta inMeta: [String: Any], echoMode: EchoMode,
                         captured: (system: Bool, mic: Bool)? = nil,
                         progress: ((Double) -> Void)? = nil) -> [String] {
        var meta = inMeta
        var warnings = (meta["warnings"] as? [String]) ?? []
        let raw = rawDir(dir)
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let f = { (name: String) in raw.appendingPathComponent(name) }
        let sysPCM = f(systemPCM), micPCM = f(micPCM)
        let hasSys = captured?.system ?? hasAudio(sysPCM)
        let hasMic = captured?.mic ?? hasAudio(micPCM)

        // Progress: each step owns a slice of 0...1 sized by its cost.
        let runAEC = echoMode == .webrtc && hasSys && hasMic
        let total = (runAEC ? Cost.aec : 0) + (hasSys || hasMic ? Cost.mix : 0)
            + (FileManager.default.fileExists(atPath: sysPCM.path) ? Cost.encodeSystem : 0)
            + (FileManager.default.fileExists(atPath: micPCM.path) ? Cost.encodeMic : 0)
        var doneCost = 0.0
        func step(_ cost: Double) -> (Double) -> Void {
            let base = doneCost
            doneCost += cost
            return { f in progress?(total > 0 ? min(1, (base + cost * min(max(f, 0), 1)) / total) : 1) }
        }
        progress?(0)

        // 1. Echo cancellation on the lossless capture.
        var aec = false
        if runAEC {
            do {
                try EchoCanceller.process(system: sysPCM, mic: micPCM, output: f("mic_aec.caf"),
                                          progress: step(Cost.aec))
                aec = true
            } catch {
                warnings.append(tr("Echo cancellation failed (the mix uses the raw mic track): ") + "\(error)")
            }
        }

        // 2. Loudness-matched mix.
        var mixInfo = Mixer.Result()
        var mixed = false
        if hasSys || hasMic {
            do {
                mixInfo = try Mixer.mix(system: hasSys ? sysPCM : nil,
                                        mic: hasMic ? (aec ? f("mic_aec.caf") : micPCM) : nil,
                                        output: dir.appendingPathComponent("mixed.m4a"),
                                        progress: step(Cost.mix))
                mixed = true
            } catch {
                warnings.append(tr("Mixing failed (the tracks are kept): ") + "\(error)")
            }
        }

        // 3. Encode tracks to AAC; drop the PCM only when the AAC file checks out.
        var tracks = (meta["tracks"] as? [String: [String: Any]]) ?? [:]
        for (key, pcm, out, bitRate, has, cost) in [("system", sysPCM, f("system.caf"), 128_000, hasSys, Cost.encodeSystem),
                                                    ("mic", micPCM, f("mic.caf"), 64_000, hasMic, Cost.encodeMic)] {
            var t = tracks[key] ?? [:]
            let encodeProgress = FileManager.default.fileExists(atPath: pcm.path) ? step(cost) : { _ in }
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
                try encodeAAC(pcm, to: out, bitRate: bitRate, progress: encodeProgress)
                t["file"] = "\(rawFolder)/\(out.lastPathComponent)"
                t["format"] = "AAC 48kHz \(key == "system" ? "stereo" : "mono") \(bitRate / 1000)kbps"
                if Subprocesses.isQuitting { return warnings }  // leave it for the next launch
                try? FileManager.default.removeItem(at: pcm)
            } catch {
                t["file"] = "\(rawFolder)/\(pcm.lastPathComponent)"  // keep the lossless capture
                t["format"] = "PCM 16-bit 48kHz"
                warnings.append(tr("%@: AAC encoding failed, kept the PCM file: ", key) + "\(error)")
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
        // Quit mid-way: steps may have failed only because they were killed. Keep status
        // "saving" so the next launch redoes the processing from the PCM files.
        if Subprocesses.isQuitting { return warnings }
        meta["status"] = meta.removeValue(forKey: "final_status") ?? "complete"
        writeMeta(meta, to: dir)
        progress?(1)
        return warnings
    }

    /// Finds sessions left unfinished and finalizes them: capture cut off by a crash or force quit
    /// ("recording"), or processing cut off by Quit, logout or shutdown ("saving").
    /// Returns the directories it processed.
    static func recoverUnfinished(root: URL, progress: ((Double) -> Void)? = nil) -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var done: [URL] = []
        for dir in dirs {
            guard var meta = readMeta(dir), ["recording", "saving"].contains(meta["status"] as? String ?? "") else { continue }
            // Skip a capture whose recording process is still alive (e.g. another running instance).
            if let pid = meta["pid"] as? Int32, pid != getpid(), kill(pid, 0) == 0 { continue }
            let mode = (meta["echo_cancellation"] as? String).flatMap(EchoMode.init(rawValue:)) ?? .off
            if meta["status"] as? String == "saving", meta["final_status"] != nil {
                // Capture ended cleanly; only processing was interrupted. The metadata is complete.
                meta["processing_resumed_at"] = ISO8601DateFormatter().string(from: Date())
                finalize(dir: dir, meta: meta, echoMode: mode, progress: progress)
                done.append(dir)
                continue
            }
            let raw = rawDir(dir)
            let dur = max(duration(raw.appendingPathComponent(systemPCM)), duration(raw.appendingPathComponent(micPCM)))
            meta["status"] = "recovered_after_crash"
            meta["duration_sec"] = dur
            var w = (meta["warnings"] as? [String]) ?? []
            w.append(tr("The app quit unexpectedly while recording; recovered about %@ s from the capture files.", Int(dur)))
            meta["warnings"] = w
            finalize(dir: dir, meta: meta, echoMode: mode, progress: progress)
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
    /// afconvert has no progress output, so progress = output size / expected size.
    private static func encodeAAC(_ input: URL, to output: URL, bitRate: Int,
                                  progress: @escaping (Double) -> Void) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "caff", "-d", "aac", "-b", String(bitRate), input.path, output.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try Subprocesses.run(p)
        defer { Subprocesses.finished(p) }
        let expectedBytes = max(1, Double(bitRate) / 8 * duration(input))
        let poll = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        poll.schedule(deadline: .now(), repeating: 0.25)
        poll.setEventHandler {
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            progress(min(0.99, Double(size) / expectedBytes))
        }
        poll.resume()
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        poll.cancel()
        progress(1)
        guard p.terminationStatus == 0 else { throw CAError(what: "afconvert: \(msg)", status: p.terminationStatus) }
        // Sanity check: encoded length must match the capture (within AAC frame granularity).
        let a = duration(input), b = duration(output)
        guard abs(a - b) < 0.1 else {
            throw CAError(what: "AAC duration \(b)s != PCM \(a)s", status: -1)
        }
    }
}

/// Child processes (ffmpeg, afconvert) still running, so they can be stopped when the app quits.
/// Otherwise an orphaned encoder could keep writing a file that the next launch reprocesses.
enum Subprocesses {
    private static let lock = NSLock()
    private static var running: [ObjectIdentifier: Process] = [:]
    private static var quitting = false

    /// Set once the app is quitting: processing must not delete or finalize anything after that.
    static var isQuitting: Bool { lock.lock(); defer { lock.unlock() }; return quitting }

    static func run(_ p: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if quitting { throw CAError(what: "app is quitting", status: -1) }
        try p.run()
        running[ObjectIdentifier(p)] = p
    }

    static func finished(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        running[ObjectIdentifier(p)] = nil
    }

    static func terminateAll() {
        lock.lock(); defer { lock.unlock() }
        quitting = true
        for p in running.values where p.isRunning { p.terminate() }
        running.removeAll()
    }
}
