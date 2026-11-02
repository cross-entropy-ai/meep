import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// One capture lifecycle of the mic track's input device (see preferredInputDevice).
/// - System default input: AVAudioEngine's input node (needed for Apple voice processing).
/// - A chosen device that is not the default: an IO proc on that device. AVAudioEngine's input
///   and output share one HAL unit on macOS; pointing its input at another device than the
///   default leaves the node's formats out of sync and the engine fails to start, intermittently.
/// Recovery = stop() this instance and start a new one; the TrackWriter keeps the file continuous.
/// Concurrency: start/resume/stop run on the session's control queue; audio callbacks only
/// touch the atomic heartbeat, the (Sendable) writer and, in device mode, `deviceFormat` on `ioQueue`.
final class MicRecorder: @unchecked Sendable {
    /// Apple voice processing (echo cancellation of speaker playback) on the mic.
    let voiceProcessing: Bool
    /// Called (on an arbitrary queue) when the engine's audio route/configuration changed.
    var onConfigurationChange: (@Sendable () -> Void)?

    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private let lastCallback = Atomic<UInt64>(0)
    var lastCallbackHost: UInt64 { lastCallback.load(ordering: .relaxed) }
    private(set) var inputDeviceName = ""
    private(set) var inputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private(set) var voiceProcessingActive = false

    // Device mode (IO proc on a chosen, non-default device).
    private var procID: AudioDeviceIOProcID?
    private var deviceFormat: AVAudioFormat?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private let ioQueue = DispatchQueue(label: "mic-io", qos: .userInteractive)
    /// Whether the engine was set up (device mode never touches it). The engine records the
    /// system default input, whatever it is at the moment.
    private(set) var usesEngine = false

    init(voiceProcessing: Bool) {
        self.voiceProcessing = voiceProcessing
    }

    var isRunning: Bool { procID != nil || engine.isRunning }

    func start(writer: TrackWriter) throws {
        let def = try? defaultDevice(output: false)
        if let want = preferredInputDevice(), want != def {
            do { try startDevice(want, writer: writer) } catch { stop(); throw error }
            return
        }
        if let def {
            inputDeviceID = def
            inputDeviceName = (try? readStringProperty(def, kAudioObjectPropertyName)) ?? "?"
        }
        usesEngine = true
        let input = engine.inputNode

        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The voice unit makes macOS treat this like a call and duck other audio; keep it minimal.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
                voiceProcessingActive = true
            } catch {
                NSLog("MeetingRecorder: voice processing unavailable (%@), recording raw mic", "\(error)")
            }
        }

        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
            throw CAError(what: "No microphone input available", status: -1)
        }
        // Explicit mono tap format: never inherit odd multichannel route formats
        // (with voice processing a 9-channel route can yield pure silence).
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFmt.sampleRate,
                                 channels: 1, interleaved: false)!
        if voiceProcessingActive {
            // VoiceProcessingIO is a duplex unit: it only produces input when its output side
            // renders too. Nothing is played; the connection just completes the graph.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: mono)
        }
        let tapFormat = voiceProcessingActive ? mono : inFmt
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, when in
            guard let self else { return }
            self.lastCallback.store(mach_absolute_time(), ordering: .relaxed)
            writer.append(buffer, hostTime: when.isHostTimeValid ? when.hostTime : mach_absolute_time())
        }

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.onConfigurationChange?() }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    // MARK: Device mode

    private func startDevice(_ dev: AudioDeviceID, writer: TrackWriter) throws {
        inputDeviceID = dev
        inputDeviceName = (try? readStringProperty(dev, kAudioObjectPropertyName)) ?? "?"
        if voiceProcessing {
            NSLog("MeetingRecorder: voice processing needs the default input; recording %@ raw", inputDeviceName)
        }
        guard let fmt = Self.inputFormat(dev) else {
            throw CAError(what: "No input format on \(inputDeviceName)", status: -1)
        }
        deviceFormat = fmt

        // Sample rate changes (another app reconfiguring the device) change the buffer layout.
        var addr = propAddress(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.deviceFormat = Self.inputFormat(dev)  // runs on ioQueue
        }
        if AudioObjectAddPropertyListenerBlock(dev, &addr, ioQueue, listener) == noErr { formatListener = listener }

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, dev, ioQueue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            guard let self, let fmt = self.deviceFormat else { return }
            let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            // First input stream only (multi-stream interfaces: its first channels).
            guard let first = all.first, first.mNumberChannels > 0,
                  first.mNumberChannels == (fmt.isInterleaved ? fmt.channelCount : 1) else { return }
            let mono = fmt.isInterleaved ? fmt : AVAudioFormat(
                commonFormat: fmt.commonFormat, sampleRate: fmt.sampleRate, channels: 1, interleaved: false)!
            var one = AudioBufferList(mNumberBuffers: 1, mBuffers: first)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: mono, bufferListNoCopy: &one, deallocator: nil),
                  pcm.frameLength > 0 else { return }
            let host = inInputTime.pointee.mFlags.contains(.hostTimeValid)
                ? inInputTime.pointee.mHostTime : mach_absolute_time()
            self.lastCallback.store(mach_absolute_time(), ordering: .relaxed)
            writer.append(pcm, hostTime: host)  // converts (copies) before returning
        }, "AudioDeviceCreateIOProcIDWithBlock")
        try check(AudioDeviceStart(dev, procID), "AudioDeviceStart")
    }

    /// Format of the device's first input stream as IO procs see it.
    private static func inputFormat(_ dev: AudioDeviceID) -> AVAudioFormat? {
        var addr = propAddress(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &asbd) == noErr,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    // MARK: -

    /// Restart the same engine after a configuration change (Apple's recommended handling).
    /// Returns whether it is running afterwards.
    @discardableResult
    func resume() -> Bool {
        if isRunning || !usesEngine { return isRunning }
        engine.prepare()
        return (try? engine.start()) != nil && engine.isRunning
    }

    /// Safe to call repeatedly, and after the device has vanished.
    func stop() {
        if let procID {
            AudioDeviceStop(inputDeviceID, procID)
            AudioDeviceDestroyIOProcID(inputDeviceID, procID)
            self.procID = nil
        }
        if let formatListener {
            var addr = propAddress(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
            AudioObjectRemovePropertyListenerBlock(inputDeviceID, &addr, ioQueue, formatListener)
            self.formatListener = nil
        }
        ioQueue.sync {}  // drain in-flight IO callbacks
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if usesEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}
