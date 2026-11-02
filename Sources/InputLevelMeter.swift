import CoreAudio
import Foundation
import Synchronization

/// Live peak level of an input device, for the meter in Preferences. Runs its own IO proc, so it
/// works whether or not a recording is running (which has its own on the same device).
/// Concurrency: start/stop on the main thread; the IO proc writes `peak` atomically.
final class InputLevelMeter: @unchecked Sendable {
    let device: AudioDeviceID
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "level-meter-io", qos: .userInitiated)
    /// Highest sample magnitude since the last read, as Float bits.
    private let peakBits = Atomic<UInt32>(0)

    init?(device: AudioDeviceID) {
        self.device = device
        // IO procs see the stream's virtual format, Float32 for shared (non-hogged) input.
        var addr = propAddress(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &asbd) == noErr,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return nil }
        let ok = AudioDeviceCreateIOProcIDWithBlock(&procID, device, ioQueue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            var peak: Float = 0
            for buf in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buf.mData else { continue }
                let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in 0..<n { peak = max(peak, abs(samples[i])) }
            }
            let old = Float(bitPattern: self.peakBits.load(ordering: .relaxed))
            if peak > old { self.peakBits.store(peak.bitPattern, ordering: .relaxed) }
        } == noErr
        guard ok, AudioDeviceStart(device, procID) == noErr else {
            stop()
            return nil
        }
    }

    /// Peak since the last call, 0...1.
    func readPeak() -> Float {
        min(1, Float(bitPattern: peakBits.exchange(0, ordering: .relaxed)))
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
        ioQueue.sync {}
    }

    deinit { stop() }
}
