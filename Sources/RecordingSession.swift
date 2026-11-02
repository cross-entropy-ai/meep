import AVFoundation
import CoreAudio
import Foundation

/// One meeting recording.
///
/// Capture writes crash-safe PCM (system.pcm.caf, mic.pcm.caf); after stop the Finalizer produces
/// (all tracks start at session start; sample N of every file is the same moment):
///   system.caf   everything the Mac played, AAC 48 kHz stereo
///   mic.caf      microphone, AAC 48 kHz mono (Apple-processed if echo mode = apple)
///   mic_aec.caf  WebRTC AEC3 echo-cancelled mic (echo mode = webrtc)
///   mixed.m4a    loudness-matched mix
///   session.json metadata, interruptions, warnings (written at start with status "recording")
///
/// Capture recovery: default-device changes, device removal, engine reconfiguration and a 1 s
/// watchdog restart the affected track; the TrackWriter pads the gap so the file stays continuous.
final class RecordingSession {
    enum Track: String { case mic, system }

    struct Interruption {
        let track: Track
        let reason: String
        let detectedAt: Double
        var recoveredAt: Double?
        var attempts = 0
        var device: String?
        var lastError: String?
    }

    enum Health: Equatable { case ok, recovering(Track), lost(Track) }

    let directory: URL
    let startedAt = Date()
    let echoMode: EchoMode
    private let startHost = mach_absolute_time()
    private let control = DispatchQueue(label: "session-control")

    private var systemWriter: TrackWriter!
    private var micWriter: TrackWriter!
    private var system: SystemAudioRecorder?
    private var mic: MicRecorder?
    private var trackStartedAt: [Track: Double] = [:]

    private var interruptions: [Interruption] = []
    private var openInterruption: [Track: Int] = [:]
    private var nextRetry: [Track: Double] = [:]
    private var pendingRestart: Set<Track> = []
    private var systemStallHandled = false

    private var timer: DispatchSourceTimer?
    private var listener: HardwareListener?
    private var activity: NSObjectProtocol?
    private var stopped = false
    private(set) var warnings: [String] = []

    static let micStallSeconds = 2.0
    static let systemStallSeconds = 5.0
    static let lostAfterAttempts = 3

    static var rootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MeetingRecordings", isDirectory: true)
    }

    init(echoMode: EchoMode = AppSettings.echoMode) throws {
        self.echoMode = echoMode
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        directory = Self.rootDirectory.appendingPathComponent(f.string(from: startedAt), isDirectory: true)
        try FileManager.default.createDirectory(at: Finalizer.rawDir(directory), withIntermediateDirectories: true)
    }

    private var systemPCM: URL { Finalizer.rawDir(directory).appendingPathComponent(Finalizer.systemPCM) }
    private var micPCM: URL { Finalizer.rawDir(directory).appendingPathComponent(Finalizer.micPCM) }

    private func now() -> Double { hostTimeToSeconds(mach_absolute_time()) - hostTimeToSeconds(startHost) }

    // MARK: - Start / stop

    func start() throws {
        systemWriter = try TrackWriter(url: systemPCM, channels: 2, sessionStart: startHost)
        micWriter = try TrackWriter(url: micPCM, channels: 1, sessionStart: startHost)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording meeting")

        var errors: [String] = []
        control.sync {
            if let e = startTrack(.system) { errors.append(tr("System audio failed to start: ", "系统声音录制失败: ") + e) }
            if let e = startTrack(.mic) { errors.append(tr("Microphone failed to start: ", "麦克风录制失败: ") + e) }
        }
        if errors.count == 2 {
            control.sync { stopped = true; system?.stop(); mic?.stop() }
            endActivity()
            throw CAError(what: errors.joined(separator: "\n"), status: -1)
        }
        // A track that failed to start is retried by the watchdog like any other interruption;
        // if it never comes back, stop() reports it.
        control.sync {
            let down: [(Track, Bool)] = [(.system, system == nil), (.mic, mic == nil)]
            for (t, isDown) in down where isDown {
                beginInterruption(t, reason: "start_failed")
                interruptions[openInterruption[t]!].lastError = errors.first
                nextRetry[t] = now() + 2
            }
        }

        listener = HardwareListener(queue: control, selectors: [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices,
        ]) { [weak self] sel in self?.hardwareChanged(sel) }

        control.sync { writeMeta(status: "recording") }

        let t = DispatchSource.makeTimerSource(queue: control)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.watchdog() }
        t.resume()
        timer = t
    }

    /// Current capture health, for the menu bar.
    var health: Health {
        control.sync {
            for t in [Track.mic, .system] {
                if let i = openInterruption[t] {
                    return interruptions[i].attempts > Self.lostAfterAttempts ? .lost(t) : .recovering(t)
                }
            }
            return .ok
        }
    }

    /// Stops capture, runs echo cancellation (webrtc mode) and the mix, writes session.json.
    /// Returns warnings to show the user. Blocking; call off the main thread.
    func stop() -> [String] {
        let stopHost = mach_absolute_time()
        control.sync {
            stopped = true
            timer?.cancel(); timer = nil
            listener?.cancel(); listener = nil
            system?.stop(); system = nil
            mic?.stop(); mic = nil
            writeMeta(status: "saving")  // visible to `--status` while post-processing runs
        }
        systemWriter.finish(at: stopHost)
        micWriter.finish(at: stopHost)
        endActivity()
        let stoppedAt = Date()
        let duration = hostTimeToSeconds(stopHost) - hostTimeToSeconds(startHost)

        if let e = systemWriter.error { warnings.append(tr("System audio write error: ", "系统声音写文件出错: ") + "\(e)") }
        if let e = micWriter.error { warnings.append(tr("Microphone write error: ", "麦克风写文件出错: ") + "\(e)") }
        let hasSys = systemWriter.buffersCaptured > 0
        let hasMic = micWriter.buffersCaptured > 0
        if hasSys && systemWriter.peak == 0 {
            warnings.append(tr("System audio was silent the whole time. If there was sound, allow MeetingRecorder in System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only.", "系统声音全程无信号。若会议中确实有声音，请到 系统设置 › 隐私与安全性 › 屏幕与系统录音 › 仅系统录音 中允许 MeetingRecorder。"))
        }
        if hasMic && micWriter.peak == 0 {
            warnings.append(tr("The microphone was silent the whole time. Check the microphone permission or input device.", "麦克风全程无信号，请检查麦克风权限或输入设备。"))
        }
        for i in interruptions where i.recoveredAt == nil {
            warnings.append(i.track == .mic
                ? tr("Microphone stopped at \(Self.clock(i.detectedAt)) and could not be restored (\(i.reason)).", "麦克风在 \(Self.clock(i.detectedAt)) 中断后未能恢复（\(i.reason)）。")
                : tr("System audio stopped at \(Self.clock(i.detectedAt)) and could not be restored (\(i.reason)).", "系统声音在 \(Self.clock(i.detectedAt)) 中断后未能恢复（\(i.reason)）。"))
        }

        let status = interruptions.contains { $0.recoveredAt == nil } ? "incomplete"
            : (interruptions.isEmpty ? "complete" : "recovered")
        var meta = baseMeta(status: status)
        meta["stopped_at"] = ISO8601DateFormatter().string(from: stoppedAt)
        meta["duration_sec"] = duration
        meta["tracks"] = [
            "system": ["peak": systemWriter.peak],
            "mic": ["peak": micWriter.peak,
                    "processing": echoMode == .apple ? "Apple voice processing" : "none"],
        ]
        meta["warnings"] = warnings
        return Finalizer.finalize(dir: directory, meta: meta, echoMode: echoMode, captured: (hasSys, hasMic))
    }

    /// Metadata known during capture. Written at start and on every interruption change, so a
    /// crash leaves enough behind for Finalizer.recoverUnfinished().
    private func baseMeta(status: String) -> [String: Any] {
        [
            "schema_version": 2,
            "pid": getpid(),  // lets crash recovery tell a dead capture from a live one
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "status": status,
            "echo_cancellation": echoMode.rawValue,
            "alignment": "all tracks start at session start; no offsets needed",
            "interruptions": interruptions.map { i -> [String: Any] in
                [
                    "track": i.track.rawValue, "reason": i.reason,
                    "detected_at_sec": i.detectedAt, "recovered_at_sec": i.recoveredAt ?? NSNull(),
                    "attempts": i.attempts, "device": i.device ?? NSNull(), "last_error": i.lastError ?? NSNull(),
                ]
            },
        ]
    }

    private func writeMeta(status: String) {
        Finalizer.writeMeta(baseMeta(status: status), to: directory)
    }

    private func endActivity() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    // MARK: - Capture lifecycle (control queue only)

    /// Starts a fresh recorder for `track`. Returns an error description on failure.
    private func startTrack(_ track: Track) -> String? {
        switch track {
        case .system:
            let r = SystemAudioRecorder()
            do { try r.start(writer: systemWriter) } catch { return "\(error)" }
            system = r
            systemStallHandled = false
        case .mic:
            let r = MicRecorder(voiceProcessing: echoMode == .apple)
            r.onConfigurationChange = { [weak self, weak r] in
                // The engine stops on a configuration change (voice processing even causes one
                // itself right after starting). First just start the same engine again; rebuild
                // only if it is still stopped a moment later. Stalls are the watchdog's job.
                self?.control.async {
                    guard let self, let r, self.mic === r else { return }
                    r.resume()
                    self.control.asyncAfter(deadline: .now() + 1.5) {
                        guard self.mic === r, !r.isRunning, !r.resume() else { return }
                        self.scheduleRestart(.mic, reason: "route_changed")
                    }
                }
            }
            do { try r.start(writer: micWriter) } catch { return "\(error)" }
            mic = r
        }
        trackStartedAt[track] = now()
        return nil
    }

    private func beginInterruption(_ track: Track, reason: String) {
        if openInterruption[track] == nil {
            interruptions.append(Interruption(track: track, reason: reason, detectedAt: now()))
            openInterruption[track] = interruptions.count - 1
            if !stopped { writeMeta(status: "recording") }
        }
    }

    /// Coalesces bursts of hardware notifications into one restart.
    private func scheduleRestart(_ track: Track, reason: String) {
        guard !stopped, !pendingRestart.contains(track) else { return }
        pendingRestart.insert(track)
        control.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pendingRestart.remove(track)
            self?.restart(track, reason: reason)
        }
    }

    private func restart(_ track: Track, reason: String) {
        guard !stopped else { return }
        beginInterruption(track, reason: reason)
        let idx = openInterruption[track]!
        interruptions[idx].attempts += 1
        switch track {
        case .system: system?.stop(); system = nil
        case .mic: mic?.stop(); mic = nil
        }
        if let err = startTrack(track) {
            interruptions[idx].lastError = err
            let backoff = min(30, pow(2, Double(min(interruptions[idx].attempts, 5))))  // 2,4,8,16,30 s
            nextRetry[track] = now() + backoff
            NSLog("MeetingRecorder: restart %@ failed (attempt %d): %@", track.rawValue, interruptions[idx].attempts, err)
        } else {
            interruptions[idx].recoveredAt = now()
            interruptions[idx].device = track == .system ? system?.outputDeviceName : mic?.inputDeviceName
            interruptions[idx].lastError = nil
            openInterruption[track] = nil
            nextRetry[track] = nil
        }
        writeMeta(status: "recording")
    }

    private func hardwareChanged(_ sel: AudioObjectPropertySelector) {
        guard !stopped else { return }
        switch sel {
        case kAudioHardwarePropertyDefaultInputDevice:
            if let cur = try? defaultDevice(output: false), cur != mic?.inputDeviceID {
                scheduleRestart(.mic, reason: "default_input_changed")
            }
        case kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioHardwarePropertyDefaultOutputDevice:
            if let cur = try? defaultDevice(output: true), cur != system?.outputDeviceID {
                scheduleRestart(.system, reason: "default_output_changed")
                // AVAudioEngine is bound to the output device too (voice processing uses it as the
                // echo reference), and stalls when it changes. Restart now instead of waiting
                // for the watchdog.
                scheduleRestart(.mic, reason: "default_output_changed")
            }
        case kAudioHardwarePropertyDevices:
            if let s = system, !deviceIsAlive(s.outputDeviceID) {
                scheduleRestart(.system, reason: "output_device_removed")
                scheduleRestart(.mic, reason: "output_device_removed")
            }
            // The device list also changes when other clients create private devices (voice
            // processing does), so act only if the device we capture from is actually gone.
            if let m = mic, !deviceIsAlive(m.inputDeviceID) {
                scheduleRestart(.mic, reason: "input_device_removed")
            }
        default: break
        }
    }

    private func watchdog() {
        guard !stopped else { return }
        let t = now()
        // Retry tracks that are down.
        for track in [Track.mic, .system] {
            if let at = nextRetry[track], at <= t, let i = openInterruption[track] {
                restart(track, reason: interruptions[i].reason)
            }
        }
        // Mic: input devices deliver continuously, so a gap in callbacks means a stall.
        if let m = mic, openInterruption[.mic] == nil, !pendingRestart.contains(.mic) {
            let started = trackStartedAt[.mic] ?? t
            let last = m.lastCallbackHost > 0 ? secondsSince(m.lastCallbackHost) : t - started
            // Voice processing takes ~1.5 s to start delivering audio; don't count that as a stall.
            let grace = m.voiceProcessingActive ? 3.0 : Self.micStallSeconds
            if last > Self.micStallSeconds && t - started > grace { restart(.mic, reason: "mic_stalled") }
        }
        // System: some output devices (e.g. Bluetooth) stop calling back while nothing plays,
        // so a callback gap may be legitimate silence. Restart once per gap, not repeatedly.
        if let s = system, openInterruption[.system] == nil, !pendingRestart.contains(.system) {
            let last = s.lastCallbackHost > 0 ? secondsSince(s.lastCallbackHost) : t - (trackStartedAt[.system] ?? t)
            if last < 1 {
                systemStallHandled = false
            } else if last > Self.systemStallSeconds && !systemStallHandled {
                restart(.system, reason: "system_stalled")
                systemStallHandled = true
            }
        }
    }

    private func secondsSince(_ host: UInt64) -> Double {
        hostTimeToSeconds(mach_absolute_time()) - hostTimeToSeconds(host)
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }
}
