import AVFoundation
import CoreAudio
import Foundation

/// One capture lifecycle of the default input device with AVAudioEngine.
/// Recovery = stop() this instance and start a new one; the TrackWriter keeps the file continuous.
final class MicRecorder {
    /// Apple voice processing (echo cancellation of speaker playback) on the mic.
    let voiceProcessing: Bool
    /// Called (on an arbitrary queue) when the engine's audio route/configuration changed.
    var onConfigurationChange: (() -> Void)?

    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private(set) var lastCallbackHost: UInt64 = 0
    private(set) var inputDeviceName = ""
    private(set) var inputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private(set) var voiceProcessingActive = false

    init(voiceProcessing: Bool) {
        self.voiceProcessing = voiceProcessing
    }

    var isRunning: Bool { engine.isRunning }

    func start(writer: TrackWriter) throws {
        let input = engine.inputNode
        if let dev = try? defaultDevice(output: false) {
            inputDeviceID = dev
            inputDeviceName = (try? readStringProperty(dev, kAudioObjectPropertyName)) ?? "?"
        }

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
            self.lastCallbackHost = mach_absolute_time()
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

    /// Restart the same engine after a configuration change (Apple's recommended handling).
    /// Returns whether it is running afterwards.
    @discardableResult
    func resume() -> Bool {
        if engine.isRunning { return true }
        engine.prepare()
        return (try? engine.start()) != nil && engine.isRunning
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
