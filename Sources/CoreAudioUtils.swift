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
