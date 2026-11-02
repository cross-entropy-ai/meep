import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// One capture lifecycle of everything the Mac plays (all processes), via a Core Audio process
/// tap on a private aggregate device built on the current default output device.
/// Requires the "System Audio Recording Only" permission (NSAudioCaptureUsageDescription).
/// Recovery = stop() this instance and start a new one; the TrackWriter keeps the file continuous.
/// Concurrency: start/stop run on the session's control queue; `format` is set before the IO proc
/// starts and afterwards touched only on `ioQueue`; stop() drains `ioQueue`.
final class SystemAudioRecorder: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private let ioQueue = DispatchQueue(label: "system-audio-io", qos: .userInteractive)

    /// Output device the aggregate is built on.
    private(set) var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private(set) var outputDeviceName = ""
    /// Host time of the last IO callback that delivered usable audio (0 = none yet). Read by the watchdog.
    private let lastCallback = Atomic<UInt64>(0)
    var lastCallbackHost: UInt64 { lastCallback.load(ordering: .relaxed) }

    func start(writer: TrackWriter) throws {
        do {
            try setUp(writer: writer)
        } catch {
            stop()
            throw error
        }
    }

    private func setUp(writer: TrackWriter) throws {
        // 1. Global stereo tap of every process' output, nothing excluded.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "MeetingRecorder System Tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "AudioHardwareCreateProcessTap")

        // 2. Tap stream format.
        guard let fmt = readTapFormat() else {
            throw CAError(what: "AVAudioFormat from tap format", status: -1)
        }
        format = fmt

        // 3. Private aggregate device = default output device + our tap.
        outputDeviceID = try defaultDevice(output: true)
        outputDeviceName = (try? readStringProperty(outputDeviceID, kAudioObjectPropertyName)) ?? "?"
        let outputUID = try readStringProperty(outputDeviceID, kAudioDevicePropertyDeviceUID)
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetingRecorder Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID),
                  "AudioHardwareCreateAggregateDevice")

        // 4. IO proc: wrap the realtime buffer, hand it to the writer (which copies/converts).
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            guard let self, var fmt = self.format else { return }
            let host = inInputTime.pointee.mFlags.contains(.hostTimeValid)
                ? inInputTime.pointee.mHostTime : mach_absolute_time()
            var buf = Self.tapBuffer(fmt, inInputData)
            if buf == nil, let fresh = self.readTapFormat() {
                // The tap's format can change under us. Re-read it and retry.
                fmt = fresh
                self.format = fresh
                buf = Self.tapBuffer(fmt, inInputData)
            }
            guard let (pcm, list) = buf else { return }
            defer { free(list.unsafeMutablePointer) }
            guard pcm.frameLength > 0 else { return }
            // Heartbeat only on usable data: callbacks that deliver nothing count as a stall.
            self.lastCallback.store(mach_absolute_time(), ordering: .relaxed)
            writer.append(pcm, hostTime: host)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    /// The aggregate's input = input streams of its sub-device (if any) followed by the tap's
    /// stream(s). Usually the sub-device has no input, but e.g. Apple voice processing gives the
    /// output device an input stream, so pick the tap's buffers from the end of the list.
    private static func tapBuffer(_ fmt: AVAudioFormat, _ abl: UnsafePointer<AudioBufferList>)
        -> (AVAudioPCMBuffer, UnsafeMutableAudioBufferListPointer)? {
        let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        let need = fmt.isInterleaved ? 1 : Int(fmt.channelCount)
        guard all.count >= need else { return nil }
        let sub = AudioBufferList.allocate(maximumBuffers: need)
        for i in 0..<need { sub[i] = all[all.count - need + i] }
        let perBuffer = fmt.isInterleaved ? fmt.channelCount : 1
        guard sub.allSatisfy({ $0.mNumberChannels == perBuffer }),
              let pcm = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: sub.unsafePointer, deallocator: nil)
        else { free(sub.unsafeMutablePointer); return nil }
        return (pcm, sub)
    }

    private func readTapFormat() -> AVAudioFormat? {
        guard var asbd: AudioStreamBasicDescription = try? readProperty(
            tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription()) else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    /// Safe to call repeatedly, and after the underlying device has vanished.
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            procID = nil
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        // Drain in-flight IO callbacks before the caller drops us.
        ioQueue.sync {}
    }
}
