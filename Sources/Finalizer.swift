import AVFoundation
import Foundation
import Synchronization

/// Turns a session's raw PCM capture into the final outputs. Used after a normal stop and to
/// finish sessions left behind by a crash or a quit during processing (session.json status
/// "recording" or "saving").
///
///   raw/system.pcm.caf ─┬──────────────────────────────────────┬─► mixed.m4a
///   raw/mic.pcm.caf ────┴─► [WebRTC APM] ──► raw/mic_aec.pcm.caf ┘
///   then each *.pcm.caf → *.caf (AAC: system, mic, mic_aec); a PCM file is deleted only after
///   its AAC file checks out. Every intermediate is lossless.
///   WebRTC APM = echo cancellation (needs the system track) + noise suppression + auto level, as
///   set at recording time. mic_aec keeps its name (scripts rely on it) also when only noise
///   suppression / auto level ran.
///
/// Once mic processing and the mix are done, session.json records `"processing": {"stage": "encoding"}`;
/// a recovery from there only finishes the encoding (AEC/mix inputs may already be gone).
enum Finalizer {
    static let systemPCM = "system.pcm.caf"
    static let micPCM = "mic.pcm.caf"
    static let micAECPCM = "mic_aec.pcm.caf"
    static let rawFolder = "raw"

    /// Layout:  <session>/mixed.m4a  +  <session>/raw/{system,mic,mic_aec}.caf, session.json
    static func rawDir(_ dir: URL) -> URL { dir.appendingPathComponent(rawFolder, isDirectory: true) }

    /// Relative cost of each step, measured on 10 min of audio (M-series Mac); all scale with length.
    private enum Cost {
        static let aec = 11.6, mix = 5.0, encodeSystem = 2.5, encodeMic = 1.5, encodeMicAEC = 1.5
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
        removePartialFiles(in: [dir, raw])  // left by a run that was killed mid-write
        let f = { (name: String) in raw.appendingPathComponent(name) }
        let sysPCM = f(systemPCM), micPCM = f(micPCM), aecPCM = f(micAECPCM)
        let hasSys = captured?.system ?? hasAudio(sysPCM)
        let hasMic = captured?.mic ?? hasAudio(micPCM)
        let exists = { (u: URL) in FileManager.default.fileExists(atPath: u.path) }
        // Resuming after AEC + mix completed: only the encoding is left.
        let processing = meta["processing"] as? [String: Any]
        let resumeEncoding = processing?["stage"] as? String == "encoding"

        let options = micOptions(meta: meta, echoMode: echoMode, hasSystem: hasSys, hasMic: hasMic)

        // Progress: each step owns a slice of 0...1 sized by its cost.
        let runAEC = !resumeEncoding && hasMic && !options.summary.isEmpty
        let runMix = !resumeEncoding && (hasSys || hasMic)
        let total = (runAEC ? Cost.aec : 0) + (runMix ? Cost.mix : 0)
            + (exists(sysPCM) ? Cost.encodeSystem : 0)
            + (exists(micPCM) ? Cost.encodeMic : 0)
            + (runAEC || exists(aecPCM) ? Cost.encodeMicAEC : 0)
        var doneCost = 0.0
        func step(_ cost: Double) -> (Double) -> Void {
            let base = doneCost
            doneCost += cost
            return { f in progress?(total > 0 ? min(1, (base + cost * min(max(f, 0), 1)) / total) : 1) }
        }
        progress?(0)

        // 1. Mic processing (echo cancellation / noise suppression / auto level as set), on the
        //    lossless capture, to lossless PCM.
        var aec = processing?["aec"] as? Bool ?? false
        if runAEC {
            do {
                try MicProcessor.process(system: hasSys ? sysPCM : nil, mic: micPCM, output: aecPCM,
                                         options: options, progress: step(Cost.aec))
                aec = true
                meta["mic_processing"] = options.summary
            } catch {
                warnings.append(tr("Microphone processing failed (the mix uses the raw mic track): ") + "\(error)")
            }
        }

        // 2. Loudness-matched mix, from lossless inputs only.
        if !resumeEncoding { meta["mixed"] = NSNull() }
        if runMix {
            do {
                let info = try Mixer.mix(system: hasSys ? sysPCM : nil,
                                         mic: hasMic ? (aec ? aecPCM : micPCM) : nil,
                                         output: dir.appendingPathComponent("mixed.m4a"),
                                         progress: step(Cost.mix))
                meta["mixed"] = "mixed.m4a"
                meta["mix_loudness_lufs"] = info.loudnessLUFS
                meta["mix_gain_db"] = info.gainsDB
            } catch {
                warnings.append(tr("Mixing failed (the tracks are kept): ") + "\(error)")
            }
        }

        // Checkpoint: from here on, a recovery only re-runs the encoding below.
        // Quit mid-way: steps may have failed only because they were killed; don't record them.
        if Subprocesses.isQuitting { return warnings }
        if !resumeEncoding {
            meta["processing"] = ["stage": "encoding", "aec": aec]
            meta["warnings"] = warnings
            meta["status"] = "saving"  // still unfinished: recoverUnfinished picks it up
            writeMeta(meta, to: dir)
        }

        // 3. Encode tracks to AAC; drop the PCM only when the AAC file checks out.
        if !aec { try? FileManager.default.removeItem(at: aecPCM) }  // partial output of a failed AEC
        var tracks = (meta["tracks"] as? [String: [String: Any]]) ?? [:]
        for (key, pcm, out, bitRate, has, cost) in [("system", sysPCM, f("system.caf"), 128_000, hasSys, Cost.encodeSystem),
                                                    ("mic", micPCM, f("mic.caf"), 64_000, hasMic, Cost.encodeMic),
                                                    ("mic_aec", aecPCM, f("mic_aec.caf"), 64_000, aec, Cost.encodeMicAEC)] {
            var t = tracks[key] ?? [:]
            let note = key == "mic_aec" ? ", WebRTC " + (meta["mic_processing"] as? String ?? "AEC3") : ""
            let encodeProgress = exists(pcm) ? step(cost) : { _ in }
            if !exists(pcm), exists(out), key != "mic_aec" || aec {
                t["file"] = "\(rawFolder)/\(out.lastPathComponent)"  // encoded before a crash
                t["duration_sec"] = duration(out)
                t["format"] = "AAC 48kHz \(key == "system" ? "stereo" : "mono") \(bitRate / 1000)kbps" + note
                tracks[key] = t
                continue
            }
            t["duration_sec"] = duration(pcm)
            // mic_aec is derived, not captured: without a successful AEC there is nothing to keep.
            if key == "mic_aec" && !aec {
                t["file"] = NSNull()
                t["format"] = NSNull()
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
                t["format"] = "AAC 48kHz \(key == "system" ? "stereo" : "mono") \(bitRate / 1000)kbps" + note
                if Subprocesses.isQuitting { return warnings }  // leave it for the next launch
                try? FileManager.default.removeItem(at: pcm)
            } catch {
                t["file"] = "\(rawFolder)/\(pcm.lastPathComponent)"  // keep the lossless file
                t["format"] = "PCM 16-bit 48kHz" + note
                warnings.append(tr("%@: AAC encoding failed, kept the PCM file: ", key) + "\(error)")
            }
            tracks[key] = t
        }

        meta["tracks"] = tracks
        meta["warnings"] = warnings
        meta.removeValue(forKey: "processing")
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
            // Skip a recording whose process is alive: another running instance, or this one
            // (a recording that started while recovery was listing the folder).
            if let pid = meta["pid"] as? Int32, kill(pid, 0) == 0 { continue }
            // From here this process owns it: the CLI then sees it busy (aec/remix refuse it).
            meta["pid"] = getpid()
            writeMeta(meta, to: dir)
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
            meta["status"] = "saving"
            meta["final_status"] = "recovered_after_crash"
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

    /// Mic processing for a recording, from the settings stored at recording time (older
    /// sessions: low noise suppression with echo cancellation, as before). Apple voice processing
    /// already did its own noise suppression and gain. Also used by `aec <recording-dir>`.
    static func micOptions(meta: [String: Any], echoMode: EchoMode, hasSystem: Bool, hasMic: Bool)
        -> MicProcessor.Options {
        // Older sessions only have tracks.mic.processing, and only after a clean stop.
        let tracks = meta["tracks"] as? [String: [String: Any]]
        let appleProcessed = echoMode == .apple && (meta["mic_voice_processing"] as? Bool
            ?? ((tracks?["mic"]?["processing"] as? String ?? "Apple voice processing") != "none"))
        var options = MicProcessor.Options(
            echoCancellation: echoMode == .webrtc && hasSystem && hasMic,
            noiseSuppression: (meta["noise_suppression"] as? String).flatMap(NoiseSuppression.init(rawValue:)) ?? .low,
            autoLevel: meta["auto_level"] as? Bool ?? false)
        if appleProcessed { options.noiseSuppression = .off; options.autoLevel = false }
        if !options.echoCancellation && meta["noise_suppression"] == nil { options.noiseSuppression = .off }
        return options
    }

    static func readMeta(_ dir: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: rawDir(dir).appendingPathComponent("session.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Writes `output` via a hidden temporary file next to it (same extension, which picks the
    /// format) that replaces it only when `write` succeeded: an interrupted run never leaves a
    /// truncated file under the final name.
    static func writeAtomically(to output: URL, _ write: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let temp = output.deletingLastPathComponent().appendingPathComponent(
            ".\(output.deletingPathExtension().lastPathComponent)\(partialMarker)\(output.pathExtension)")
        try? fm.removeItem(at: temp)
        do {
            try write(temp)
            // Same directory, so rename(2): atomic, replaces an existing file, works on any volume
            // (FileManager.replaceItemAt needs a scratch directory some network volumes lack).
            guard rename(temp.path, output.path) == 0 else {
                throw CAError(what: "rename to \(output.path): \(String(cString: strerror(errno)))", status: errno)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    private static let partialMarker = ".partial."

    /// Deletes temporary files writeAtomically left behind when the process was killed.
    static func removePartialFiles(in dirs: [URL]) {
        let fm = FileManager.default
        for dir in dirs {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            where name.hasPrefix(".") && name.contains(partialMarker) {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// Pretty, key-sorted JSON (session.json and CLI output).
    static func jsonData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }

    /// Returns false (and logs) if session.json could not be written, e.g. a full disk.
    @discardableResult
    static func writeMeta(_ meta: [String: Any], to dir: URL) -> Bool {
        let raw = rawDir(dir)
        do {
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            try jsonData(meta).write(to: raw.appendingPathComponent("session.json"), options: .atomic)
            return true
        } catch {
            NSLog("Meep: can't write %@/session.json: %@", raw.path, "\(error)")
            return false
        }
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
    static func encodeAAC(_ input: URL, to output: URL, bitRate: Int,
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
    private struct State {
        var running: [ObjectIdentifier: Process] = [:]
        var quitting = false
    }
    private static let state = Mutex(State())

    /// Set once the app is quitting: processing must not delete or finalize anything after that.
    static var isQuitting: Bool { state.withLock { $0.quitting } }

    /// Starts `p` with stdin = /dev/null: inheriting a terminal's stdin (Process's default) lets
    /// ffmpeg read keys (q quits early) and suspends a backgrounded CLI on SIGTTIN.
    static func run(_ p: Process) throws {
        p.standardInput = FileHandle.nullDevice
        try state.withLock { s in
            if s.quitting { throw CAError(what: "app is quitting", status: -1) }
            try p.run()
            s.running[ObjectIdentifier(p)] = p
        }
    }

    static func finished(_ p: Process) {
        state.withLock { _ = $0.running.removeValue(forKey: ObjectIdentifier(p)) }
    }

    static func terminateAll() {
        state.withLock { s in
            s.quitting = true
            for p in s.running.values where p.isRunning { p.terminate() }
            s.running.removeAll()
        }
    }
}
