import AVFoundation
import Darwin

enum PermissionStatus: Sendable {
    case authorized, denied, notDetermined
    /// Can't be read (system audio, when the TCC calls below are unavailable).
    case unknown
}

/// Microphone and "System Audio Recording Only" access.
enum Permissions {
    static let microphoneSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let systemAudioSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    /// Read through TCC when possible: AVCaptureDevice keeps reporting a denial for the life of
    /// the process, even after access is allowed in System Settings.
    static var microphone: PermissionStatus {
        let tcc = tccStatus("kTCCServiceMicrophone" as CFString)
        return tcc == .unknown ? microphoneAV : tcc
    }

    private static var microphoneAV: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // System audio capture has no public API to read or request the permission (macOS only asks
    // when a tap first starts). TCC's own preflight/request calls do both; looked up at runtime so
    // a missing symbol degrades to `.unknown` instead of failing to launch.
    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    nonisolated(unsafe) private static let tcc =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let preflight: PreflightFn? =
        dlsym(tcc, "TCCAccessPreflight").map { unsafeBitCast($0, to: PreflightFn.self) }
    private static let request: RequestFn? =
        dlsym(tcc, "TCCAccessRequest").map { unsafeBitCast($0, to: RequestFn.self) }

    static var systemAudio: PermissionStatus { tccStatus(service) }

    private static func tccStatus(_ service: CFString) -> PermissionStatus {
        guard let preflight else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system prompt (only while not determined). False if denied or unavailable.
    static func requestSystemAudio() async -> Bool {
        guard let request else { return false }
        return await withCheckedContinuation { c in
            request(service, nil) { granted in c.resume(returning: granted) }
        }
    }
}
