import CoreAudio
import Foundation

struct CAError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) failed (OSStatus \(status))" }
}

@inline(__always)
func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CAError(what: what, status: status) }
}

func propAddress(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func readProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) throws -> T {
    var addr = propAddress(selector)
    var size = UInt32(MemoryLayout<T>.size)
    var result = value
    let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
    try check(status, "AudioObjectGetPropertyData(\(selector))")
    return result
}

func readStringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var addr = propAddress(selector)
    var size = UInt32(MemoryLayout<CFString>.size)
    var cf: Unmanaged<CFString>?
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &cf), "read string property \(selector)")
    guard let s = cf?.takeRetainedValue() else { throw CAError(what: "string property nil", status: -1) }
    return s as String
}

func deviceName(_ dev: AudioDeviceID) -> String? {
    try? readStringProperty(dev, kAudioObjectPropertyName)
}

/// Format of the device's first input stream as IO procs see it (its virtual format).
func inputStreamFormat(_ dev: AudioDeviceID) -> AudioStreamBasicDescription? {
    var addr = propAddress(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &asbd) == noErr,
          asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
    return asbd
}

extension AudioTimeStamp {
    /// The capture host time of an IO callback's buffer, or now if the HAL gave none.
    var hostTimeOrNow: UInt64 { mFlags.contains(.hostTimeValid) ? mHostTime : mach_absolute_time() }
}

func defaultDevice(output: Bool) throws -> AudioDeviceID {
    let dev: AudioDeviceID = try readProperty(
        AudioObjectID(kAudioObjectSystemObject),
        output ? kAudioHardwarePropertyDefaultSystemOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
        default: AudioDeviceID(kAudioObjectUnknown))
    if dev == kAudioObjectUnknown { throw CAError(what: "no default \(output ? "output" : "input") device", status: -1) }
    return dev
}

func deviceIsAlive(_ dev: AudioDeviceID) -> Bool {
    guard dev != kAudioObjectUnknown else { return false }
    let alive: UInt32 = (try? readProperty(dev, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0))) ?? 0
    return alive != 0
}

/// Listens to system-level audio hardware property changes (default devices, device list).
final class HardwareListener: @unchecked Sendable {  // registrations: owner's queue only
    private var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let queue: DispatchQueue

    init(queue: DispatchQueue, selectors: [AudioObjectPropertySelector],
         handler: @escaping @Sendable (AudioObjectPropertySelector) -> Void) {
        self.queue = queue
        for sel in selectors {
            var addr = propAddress(sel)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler(sel) }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
                registrations.append((addr, block))
            }
        }
    }

    func cancel() {
        for (a, block) in registrations {
            var addr = a
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        }
        registrations.removeAll()
    }
}

/// Convert mach host time to seconds.
func hostTimeToSeconds(_ t: UInt64) -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(t) * Double(info.numer) / Double(info.denom) / 1e9
}

// MARK: - Input devices

struct InputDevice: Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Devices with at least one input channel, excluding private devices (this process's capture
/// aggregate, voice processing's helper devices).
func listInputDevices() -> [InputDevice] {
    var addr = propAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        guard inputChannelCount(id) > 0, !isPrivateAggregate(id),
              let uid = try? readStringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = deviceName(id) else { return nil }
        return InputDevice(id: id, uid: uid, name: name)
    }
}

private func inputChannelCount(_ dev: AudioDeviceID) -> Int {
    var addr = propAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

private func isPrivateAggregate(_ dev: AudioDeviceID) -> Bool {
    var addr = propAddress(kAudioAggregateDevicePropertyComposition)
    guard AudioObjectHasProperty(dev, &addr) else { return false }
    var size = UInt32(MemoryLayout<CFDictionary>.size)
    var cf: Unmanaged<CFDictionary>?
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &cf) == noErr,
          let dict = cf?.takeRetainedValue() as? [String: Any] else { return false }
    return (dict[kAudioAggregateDeviceIsPrivateKey] as? Int ?? 0) != 0
}

/// The device the mic track should record: the chosen input (AppSettings.inputDeviceUID) while
/// it is connected, otherwise the system default input.
func preferredInputDevice() -> AudioDeviceID? {
    let uid = AppSettings.inputDeviceUID
    if !uid.isEmpty, let d = listInputDevices().first(where: { $0.uid == uid }), deviceIsAlive(d.id) { return d.id }
    return try? defaultDevice(output: false)
}
