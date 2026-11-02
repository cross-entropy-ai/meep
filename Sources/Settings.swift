import AppKit
import ServiceManagement

enum EchoMode: String, CaseIterable {
    case off, apple, webrtc
}

/// User settings (UserDefaults domain com.junyi.MeetingRecorder).
/// CLI: `defaults write com.junyi.MeetingRecorder echoCancellation -string off|apple|webrtc`
enum AppSettings {
    private static var d: UserDefaults { .standard }

    /// Where recordings are saved: $MEETINGRECORDER_ROOT, else the `recordingsFolder` default
    /// (a path, `~` expanded), else ~/Documents/MeetingRecordings. No UI; set it with
    /// `defaults write com.junyi.MeetingRecorder recordingsFolder -string ~/Meetings`
    static var recordingsFolder: URL {
        let candidates = [ProcessInfo.processInfo.environment["MEETINGRECORDER_ROOT"],
                          d.string(forKey: "recordingsFolder")]
        for case let p? in candidates where !p.trimmingCharacters(in: .whitespaces).isEmpty {
            let path = (p as NSString).expandingTildeInPath
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MeetingRecordings", isDirectory: true)
    }

    static var echoMode: EchoMode {
        get { d.string(forKey: "echoCancellation").flatMap(EchoMode.init(rawValue:)) ?? .webrtc }
        set { d.set(newValue.rawValue, forKey: "echoCancellation") }
    }

    /// Record the system audio track (everything the Mac plays). Default on. Off = mic only.
    static var recordSystemAudio: Bool {
        get { d.object(forKey: "recordSystemAudio") as? Bool ?? true }
        set { d.set(newValue, forKey: "recordSystemAudio") }
    }

    /// UID of the input device the mic track records; empty = the system default input.
    /// When the chosen device is not connected, the system default is recorded instead.
    static var inputDeviceUID: String {
        get { d.string(forKey: "inputDeviceUID") ?? "" }
        set { d.set(newValue, forKey: "inputDeviceUID") }
    }

    /// Name of that device, to label it in Preferences while it is disconnected.
    static var inputDeviceName: String {
        get { d.string(forKey: "inputDeviceName") ?? "" }
        set { d.set(newValue, forKey: "inputDeviceName") }
    }

    /// Show the elapsed time next to the menu bar icon while recording (default on).
    static var showElapsedTime: Bool {
        get { d.object(forKey: "showElapsedTime") as? Bool ?? true }
        set { d.set(newValue, forKey: "showElapsedTime") }
    }

    /// Show the menu bar icon while idle (default on). While recording it is always shown.
    static var showMenuBarIcon: Bool {
        get { d.object(forKey: "showMenuBarIcon") as? Bool ?? true }
        set { d.set(newValue, forKey: "showMenuBarIcon") }
    }

    /// UI language (default: follow the system).
    static var language: AppLanguage {
        get { d.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .system }
        set { d.set(newValue.rawValue, forKey: "language") }
    }

    /// Shell command run after each recording is saved, with the recording folder as $1
    /// (also in $MEETINGRECORDER_DIR). Empty = none.
    static var afterSaveCommand: String {
        get { d.string(forKey: "afterSaveCommand") ?? "" }
        set { d.set(newValue, forKey: "afterSaveCommand") }
    }

    /// Reveal the recording in Finder once it has been saved (default on).
    static var openFolderAfterSaving: Bool {
        get { d.object(forKey: "openFolderAfterSaving") as? Bool ?? true }
        set { d.set(newValue, forKey: "openFolderAfterSaving") }
    }

    /// Skip the "track was silent the whole time" alert (set from the alert's "Don't show again").
    static var hideSilenceWarnings: Bool {
        get { d.bool(forKey: "hideSilenceWarnings") }
        set { d.set(newValue, forKey: "hideSilenceWarnings") }
    }

    /// Global start/stop hotkey. nil = disabled. Default ⌘⇧R.
    static var hotKey: Shortcut? {
        get {
            guard d.object(forKey: "hotKeyCode") != nil else { return .default }
            let code = d.integer(forKey: "hotKeyCode")
            if code < 0 { return nil }
            return Shortcut(keyCode: UInt16(code),
                            modifiers: NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "hotKeyModifiers"))),
                            keyLabel: d.string(forKey: "hotKeyLabel") ?? "?")
        }
        set {
            d.set(newValue.map { Int($0.keyCode) } ?? -1, forKey: "hotKeyCode")
            d.set(Int(newValue?.modifiers.rawValue ?? 0), forKey: "hotKeyModifiers")
            d.set(newValue?.keyLabel, forKey: "hotKeyLabel")
        }
    }

    /// Launch at login via SMAppService (macOS 13+). Registers this app bundle's current location.
    static var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Values from Info.plist used by the About tab. Empty = not configured.
enum AppInfo {
    private static func string(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
    static var name: String { string("CFBundleDisplayName").isEmpty ? "MeetingRecorder" : string("CFBundleDisplayName") }
    static var version: String { string("CFBundleShortVersionString") }
    static var build: String { string("CFBundleVersion") }
    static var copyright: String { string("NSHumanReadableCopyright") }
    static var privacyPolicyURL: URL? { URL(string: string("MRPrivacyPolicyURL")).flatMap { $0.scheme == nil ? nil : $0 } }
    static var termsOfUseURL: URL? { URL(string: string("MRTermsOfUseURL")).flatMap { $0.scheme == nil ? nil : $0 } }
    /// "owner/repo" whose GitHub Releases are the update source.
    static var updateRepo: String { string("MRUpdateGitHubRepo") }
}
