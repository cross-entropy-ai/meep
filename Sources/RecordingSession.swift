import AVFoundation
import CoreAudio
import Foundation

/// One meeting recording.
///
/// Capture writes crash-safe PCM (system.pcm.caf, mic.pcm.caf); after stop the Finalizer produces
/// (all tracks start at session start; sample N of every file is the same moment):
///   system.caf   everything the Mac played, AAC 48 kHz stereo
///   mic.caf      microphone, AAC 48 kHz mono (Apple-processed if echo mode = apple)
///   mic_aec.caf  mic processed by WebRTC: echo cancellation (echo mode = webrtc, system audio on),
///                noise suppression and auto level as set (see Finalizer)
///   mixed.m4a    loudness-matched mix
///   session.json metadata, interruptions, warnings (written at start with status "recording")
///
/// Capture recovery: default-device changes, device removal or return, a new input choice, engine
/// reconfiguration and a 1 s watchdog restart the affected track; the TrackWriter pads the gap so
/// the file stays continuous.
///
/// Concurrency: capture state is confined to the `control` queue. stopCapture() lets exactly one
/// caller through (the `stopped` flag, set on `control`); the stop results it fills in are read
/// only after it returns.
final class RecordingSession: @unchecked Sendable {
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
    /// Whether the system audio track is recorded (AppSettings.recordSystemAudio at start).
    let recordSystem: Bool
    /// Mic processing after stop (settings at start; stored in session.json for recovery).
    let noiseSuppression = AppSettings.noiseSuppression
    let autoLevel = AppSettings.autoLevel
    private let startHost = mach_absolute_time()
    private let control = DispatchQueue(label: "session-control")

    private var systemWriter: TrackWriter?  // nil when system audio is off
    private var micWriter: TrackWriter!
    private var system: SystemAudioRecorder?
    private var mic: MicRecorder?
    private var trackStartedAt: [Track: Double] = [:]

    private var interruptions: [Interruption] = []
    private var openInterruption: [Track: Int] = [:]
    private var nextRetry: [Track: Double] = [:]
    private var pendingRestart: Set<Track> = []
    private var systemStallHandled = false
    /// Input device the mic track last started on.
    private var micDeviceName: String?
    /// Whether the mic track ran with Apple voice processing at any point (not with a chosen
    /// non-default device). In session.json from the start, so crash recovery knows it too.
    private var micVoiceProcessing = false

    private var timer: DispatchSourceTimer?
    private var listener: HardwareListener?
    private var activity: NSObjectProtocol?
    private var stopped = false
    private(set) var warnings: [String] = []
    /// The "track was silent the whole time" subset of `warnings`; the user can mute these.
    private(set) var silenceWarnings: [String] = []

    static let micStallSeconds = 2.0
    static let systemStallSeconds = 5.0
    static let lostAfterAttempts = 3

    /// See AppSettings.recordingsFolder ($MEETINGRECORDER_ROOT, `recordingsFolder` default).
    static var rootDirectory: URL { AppSettings.recordingsFolder }

    init(echoMode: EchoMode = AppSettings.echoMode,
         recordSystem: Bool = AppSettings.recordSystemAudio) throws {
        // Echo cancellation only applies with both tracks: WebRTC needs the system track as its
        // reference, and mic-only recordings skip Apple voice processing too.
        self.echoMode = recordSystem ? echoMode : .off
        self.recordSystem = recordSystem
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
        if recordSystem {
            systemWriter = try TrackWriter(url: systemPCM, channels: 2, sessionStart: startHost)
        }
        micWriter = try TrackWriter(url: micPCM, channels: 1, sessionStart: startHost)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording meeting")

        var errors: [String] = []
        control.sync {
            if recordSystem, let e = startTrack(.system) { errors.append(tr("System audio failed to start: ") + e) }
            if let e = startTrack(.mic) { errors.append(tr("Microphone failed to start: ") + e) }
        }
        if errors.count == (recordSystem ? 2 : 1) {
            control.sync { stopped = true; system?.stop(); mic?.stop() }
            endActivity()
            throw CAError(what: errors.joined(separator: "\n"), status: -1)
        }
        // A track that failed to start is retried by the watchdog like any other interruption;
        // if it never comes back, stop() reports it.
        control.sync {
            let down: [(Track, Bool)] = [(.system, recordSystem && system == nil), (.mic, mic == nil)]
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

    /// Stops capture, then runs echo cancellation (webrtc mode), the mix and AAC encoding.
    /// Returns warnings to show the user. Blocking; call off the main thread.
    func stop(progress: ((Double) -> Void)? = nil) -> [String] {
        stopCapture()
        return Finalizer.finalize(dir: directory, meta: finalMeta, echoMode: echoMode,
                                  captured: captured, progress: progress)
    }

    private var finalMeta: [String: Any] = [:]
    private var captured = (system: false, mic: false)

    /// Stops capture and closes the PCM files. Fast. Leaves session.json at status "saving" with
    /// everything processing needs, so if the app quits before processing ends (Quit, logout,
    /// shutdown), Finalizer.recoverUnfinished() finishes it on the next launch.
    func stopCapture() {
        guard control.sync(execute: { !stopped }) else { return }
        let stopHost = mach_absolute_time()
        control.sync {
            stopped = true
            timer?.cancel(); timer = nil
            listener?.cancel(); listener = nil
            system?.stop(); system = nil
            mic?.stop(); mic = nil
            writeMeta(status: "saving")  // visible to `--status` while post-processing runs
        }
        systemWriter?.finish(at: stopHost)
        micWriter.finish(at: stopHost)
        endActivity()
        let stoppedAt = Date()
        let duration = hostTimeToSeconds(stopHost) - hostTimeToSeconds(startHost)

        if let e = systemWriter?.error { warnings.append(tr("System audio write error: ") + "\(e)") }
        if let e = micWriter.error { warnings.append(tr("Microphone write error: ") + "\(e)") }
        let hasSys = (systemWriter?.buffersCaptured ?? 0) > 0
        let hasMic = micWriter.buffersCaptured > 0
        if hasSys && systemWriter?.peak == 0 {
            silenceWarnings.append(tr("System audio was silent the whole time. If there was sound, allow MeetingRecorder in System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only."))
        }
        if hasMic && micWriter.peak == 0 {
            silenceWarnings.append(tr("The microphone was silent the whole time. Check the microphone permission or input device."))
        }
        warnings += silenceWarnings
        for i in interruptions where i.recoveredAt == nil {
            warnings.append(i.track == .mic
                ? tr("Microphone stopped at %1$@ and could not be restored (%2$@).", Self.clock(i.detectedAt), i.reason)
                : tr("System audio stopped at %1$@ and could not be restored (%2$@).", Self.clock(i.detectedAt), i.reason))
        }

        let status = interruptions.contains { $0.recoveredAt == nil } ? "incomplete"
            : (interruptions.isEmpty ? "complete" : "recovered")
        var meta = baseMeta(status: status)
        meta["stopped_at"] = ISO8601DateFormatter().string(from: stoppedAt)
        meta["duration_sec"] = duration
        meta["tracks"] = [
            "system": recordSystem ? ["peak": systemWriter?.peak ?? 0] : ["enabled": false],
            "mic": ["peak": micWriter.peak,
                    "processing": micVoiceProcessing ? "Apple voice processing" : "none"],
        ]
        meta["warnings"] = warnings
        meta["status"] = "saving"
        meta["final_status"] = status  // Finalizer sets it as status when processing is done
        Finalizer.writeMeta(meta, to: directory)
        finalMeta = meta
        captured = (hasSys, hasMic)
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
            "system_audio": recordSystem,
            "noise_suppression": noiseSuppression.rawValue,
            "auto_level": autoLevel,
            "mic_voice_processing": micVoiceProcessing,
            "mic_device": micDeviceName ?? NSNull(),
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
            guard let systemWriter else { return "system audio is off" }
            do { try r.start(writer: systemWriter) } catch { return "\(error)" }
            system = r
            systemStallHandled = false
        case .mic:
            let r = MicRecorder(voiceProcessing: echoMode == .apple)
            r.onConfigurationChange = { [weak self, weak r] in
                // The engine stops on a configuration change (voice processing even causes one
                // itself right after starting). First just start the same engine again; rebuild
                // only if it is still stopped a moment later. Stalls are the watchdog's job.
                guard let self, let r else { return }
                self.control.async { [self, r] in
                    guard self.mic === r else { return }
                    r.resume()
                    self.control.asyncAfter(deadline: .now() + 1.5) { [self, r] in
                        guard self.mic === r, !r.isRunning, !r.resume() else { return }
                        self.scheduleRestart(.mic, reason: "route_changed")
                    }
                }
            }
            do { try r.start(writer: micWriter) } catch { return "\(error)" }
            mic = r
            micDeviceName = r.inputDeviceName
            micVoiceProcessing = micVoiceProcessing || r.voiceProcessingActive
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
        guard !stopped, !pendingRestart.contains(track), track == .mic || recordSystem else { return }
        pendingRestart.insert(track)
        control.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pendingRestart.remove(track)
            self?.restart(track, reason: reason)
        }
    }

    private func restart(_ track: Track, reason: String) {
        guard !stopped, track == .mic || recordSystem else { return }
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
            micTargetChanged(reason: "default_input_changed")
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
            } else {
                micTargetChanged(reason: "input_device_connected")  // the chosen device is back
            }
        default: break
        }
    }

    /// Restarts the mic if it should now record from a different device.
    private func micTargetChanged(reason: String) {
        guard let m = mic, let want = preferredInputDevice(), want != m.inputDeviceID else { return }
        scheduleRestart(.mic, reason: reason)
    }

    /// The input device setting changed: switch the mic track over now.
    func inputDeviceSettingChanged() {
        control.async { [self] in
            guard !stopped else { return }
            micTargetChanged(reason: "input_device_selected")
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
