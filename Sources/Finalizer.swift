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

    /// Processes `dir`, merges results into `session`, writes session.json. Returns warnings.
    /// The caller holds the session's lock. `captured`: whether each track actually recorded
    /// audio (nil = unknown, e.g. crash recovery: then any non-empty file counts). `progress` gets
    /// 0...1, from the calling thread.
    @discardableResult
    static func finalize(dir: URL, session: Session, captured: (system: Bool, mic: Bool)? = nil,
                         progress: ((Double) -> Void)? = nil) -> [String] {
        var meta = session
        let raw = rawDir(dir)
        removePartialFiles(in: [dir, raw])  // left by a run that was killed mid-write
        let f = { (name: String) in raw.appendingPathComponent(name) }
        let sysPCM = f(systemPCM), micPCM = f(micPCM), aecPCM = f(micAECPCM)
        let hasSys = captured?.system ?? hasAudio(sysPCM)
        let hasMic = captured?.mic ?? hasAudio(micPCM)
        let exists = { (u: URL) in FileManager.default.fileExists(atPath: u.path) }
        // Resuming after AEC + mix completed: only the encoding is left.
        let resumeEncoding = meta.processing != nil

        let options = meta.micOptions(hasSystem: hasSys, hasMic: hasMic)

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
        var aec = meta.processing?.aec ?? false
        if runAEC {
            do {
                try MicProcessor.process(system: hasSys ? sysPCM : nil, mic: micPCM, output: aecPCM,
                                         options: options, progress: step(Cost.aec))
                aec = true
                meta.micProcessing = options.summary
            } catch {
                meta.warnings.append(tr("Microphone processing failed (the mix uses the raw mic track): ") + "\(error)")
            }
        }

        // 2. Loudness-matched mix, from lossless inputs only.
        if !resumeEncoding { meta.mixed = nil }
        if runMix {
            do {
                let info = try Mixer.mix(system: hasSys ? sysPCM : nil,
                                         mic: hasMic ? (aec ? aecPCM : micPCM) : nil,
                                         output: dir.appendingPathComponent("mixed.m4a"),
                                         progress: step(Cost.mix))
                meta.setMix(info)
            } catch {
                meta.warnings.append(tr("Mixing failed (the tracks are kept): ") + "\(error)")
            }
        }

        // Checkpoint: from here on, a recovery only re-runs the encoding below.
        // Quit mid-way: steps may have failed only because they were killed; don't record them.
        if Subprocesses.isQuitting { return meta.warnings }
        if !resumeEncoding {
            meta.processing = Session.Processing(aec: aec)
            meta.status = .saving  // still unfinished: recoverUnfinished picks it up
            meta.write(to: dir)
        }

        // 3. Encode tracks to AAC; drop the PCM only when the AAC file checks out.
        if !aec { try? FileManager.default.removeItem(at: aecPCM) }  // partial output of a failed AEC
        let note = ", WebRTC " + (meta.micProcessing ?? "AEC3")
        let steps: [(String, WritableKeyPath<Session.Tracks, Session.Track>, URL, URL, Int, Bool, Double)] = [
            ("system", \.system, sysPCM, f("system.caf"), 128_000, hasSys, Cost.encodeSystem),
            ("mic", \.mic, micPCM, f("mic.caf"), 64_000, hasMic, Cost.encodeMic),
            ("mic_aec", \.micAec, aecPCM, f("mic_aec.caf"), 64_000, aec, Cost.encodeMicAEC)]
        for (name, key, pcm, out, bitRate, has, cost) in steps {
            let isAEC = name == "mic_aec"
            var t = meta.tracks[keyPath: key]
            let format = "AAC 48kHz \(name == "system" ? "stereo" : "mono") \(bitRate / 1000)kbps" + (isAEC ? note : "")
            defer { meta.tracks[keyPath: key] = t }
            let encodeProgress = exists(pcm) ? step(cost) : { _ in }
            if !exists(pcm), exists(out), !isAEC || aec {
                t.file = "\(rawFolder)/\(out.lastPathComponent)"  // encoded before a crash
                t.durationSec = duration(out)
                t.format = format
                continue
            }
            t.durationSec = duration(pcm)
            // mic_aec is derived, not captured: without a successful AEC there is nothing to keep.
            if isAEC && !aec {
                t.file = nil
                t.format = nil
                continue
            }
            // Never discard captured data on a heuristic: anything on disk gets encoded.
            guard has || duration(pcm) > 0 else {
                t.file = nil
                try? FileManager.default.removeItem(at: pcm)
                continue
            }
            if !has { t.note = "no audio was captured on this track (silence only)" }
            do {
                try encodeAAC(pcm, to: out, bitRate: bitRate, progress: encodeProgress)
                t.file = "\(rawFolder)/\(out.lastPathComponent)"
                t.format = format
                if Subprocesses.isQuitting { return meta.warnings }  // leave it for the next launch
                try? FileManager.default.removeItem(at: pcm)
            } catch {
                t.file = "\(rawFolder)/\(pcm.lastPathComponent)"  // keep the lossless file
                t.format = "PCM 16-bit 48kHz" + (isAEC ? note : "")
                meta.warnings.append(tr("%@: AAC encoding failed, kept the PCM file: ", name) + "\(error)")
            }
        }

        meta.processing = nil
        // Quit mid-way: steps may have failed only because they were killed. Keep status
        // "saving" so the next launch redoes the processing from the PCM files.
        if Subprocesses.isQuitting { return meta.warnings }
        meta.status = meta.finalStatus ?? .complete
        meta.finalStatus = nil
        meta.write(to: dir)
        progress?(1)
        return meta.warnings
    }

    /// Finds sessions left unfinished and finalizes them: capture cut off by a crash or force quit
    /// ("recording"), or processing cut off by Quit, logout or shutdown ("saving").
    /// Returns the directories it processed.
    static func recoverUnfinished(root: URL, progress: ((Double) -> Void)? = nil) -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var done: [URL] = []
        for dir in dirs where Session.read(dir)?.status.isUnfinished ?? false {
            // Owned by a live process (another instance, or a recording this one just started): skip.
            guard let lock = SessionLock(dir) else { continue }
            defer { lock.release() }
            guard var meta = Session.read(dir), meta.status.isUnfinished else { continue }  // finished meanwhile
            if meta.status == .saving, meta.finalStatus != nil {
                // Capture ended cleanly; only processing was interrupted. The metadata is complete.
                meta.processingResumedAt = Date()
            } else {
                let raw = rawDir(dir)
                let dur = max(duration(raw.appendingPathComponent(systemPCM)), duration(raw.appendingPathComponent(micPCM)))
                meta.status = .saving
                meta.finalStatus = .recoveredAfterCrash
                meta.durationSec = dur
                meta.warnings.append(tr("The app quit unexpectedly while recording; recovered about %@ s from the capture files.", Int(dur)))
            }
            finalize(dir: dir, session: meta, progress: progress)
            done.append(dir)
        }
        return done
    }

    // MARK: - Helpers

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
