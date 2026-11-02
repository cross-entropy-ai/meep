import AppKit
import ServiceManagement

enum EchoMode: String, CaseIterable {
    case off, apple, webrtc
}

/// Mic noise suppression strength (WebRTC), applied after recording; skipped if Apple voice
/// processing ran.
enum NoiseSuppression: String, CaseIterable {
    case off, low, moderate, high
    case veryHigh = "very_high"

    var webrtcLevel: Int {
        switch self {
        case .off: 0
        case .low: 1
        case .moderate: 2
        case .high: 3
        case .veryHigh: 4
        }
    }
}

/// User settings (UserDefaults domain com.junyi.Meep). Most are written by
/// Preferences through @AppStorage with the same key and default; see `help` for the keys.
/// CLI: `defaults write com.junyi.Meep echoCancellation -string off|apple|webrtc`
enum AppSettings {
    private static var d: UserDefaults { .standard }

    /// Meep was called MeetingRecorder (com.junyi.MeetingRecorder) before 1.0. Copies those
    /// settings once, if this domain has none yet; the old domain is left as it is.
    static func migrateFromMeetingRecorder() {
        guard let id = Bundle.main.bundleIdentifier, d.persistentDomain(forName: id)?.isEmpty ?? true,
              let old = d.persistentDomain(forName: "com.junyi.MeetingRecorder"), !old.isEmpty else { return }
        d.setPersistentDomain(old, forName: id)
    }

    /// UserDefaults keys of the settings Preferences shows (also used by its @AppStorage).
    enum Key {
        static let echoCancellation = "echoCancellation"
        static let recordSystemAudio = "recordSystemAudio"
        static let noiseSuppression = "noiseSuppression"
        static let autoLevel = "autoLevel"
        static let showElapsedTime = "showElapsedTime"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let language = "language"
        static let afterSaveCommand = "afterSaveCommand"
        static let openFolderAfterSaving = "openFolderAfterSaving"
        static let recordingsFolder = "recordingsFolder"
        static let inputDeviceUID = "inputDeviceUID"
    }

    /// Defaults of those settings (also Preferences › Audio › Restore Defaults).
    enum Default {
        static let echoMode = EchoMode.webrtc
        static let recordSystemAudio = true
        static let noiseSuppression = NoiseSuppression.low
        static let autoLevel = false
        static let showElapsedTime = true
        static let showMenuBarIcon = true
        static let afterSaveCommand = ""
        static let openFolderAfterSaving = true
    }

    /// Where recordings are saved: $MEEP_ROOT, else the `recordingsFolder` default
    /// (a path, `~` expanded), else ~/Documents/MeetingRecordings. Set in Preferences › General,
    /// or `defaults write com.junyi.Meep recordingsFolder -string ~/Meetings`
    static var recordingsFolder: URL {
        folder(ProcessInfo.processInfo.environment["MEEP_ROOT"]) ?? appRecordingsFolder
    }

    /// The folder the app uses: the setting, else the default ($MEEP_ROOT never reaches
    /// an app launched through LaunchServices).
    static var appRecordingsFolder: URL {
        folder(d.string(forKey: Key.recordingsFolder)) ?? defaultRecordingsFolder
    }

    private static func folder(_ path: String?) -> URL? {
        guard let p = path, !p.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    static var defaultRecordingsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/MeetingRecordings", isDirectory: true)
    }

    /// $MEEP_ROOT wins over the setting, so Preferences can't change the folder then.
    static var recordingsFolderFromEnvironment: Bool {
        !(ProcessInfo.processInfo.environment["MEEP_ROOT"] ?? "")
            .trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func setRecordingsFolder(_ url: URL) {
        d.set(url.standardizedFileURL.path, forKey: Key.recordingsFolder)
    }

    static var echoMode: EchoMode {
        d.string(forKey: Key.echoCancellation).flatMap(EchoMode.init(rawValue:)) ?? Default.echoMode
    }

    /// Record the system audio track (everything the Mac plays). Default on. Off = mic only.
    static var recordSystemAudio: Bool {
        d.object(forKey: Key.recordSystemAudio) as? Bool ?? Default.recordSystemAudio
    }

    /// UID of the input device the mic track records; empty = the system default input.
    /// When the chosen device is not connected, the system default is recorded instead.
    static var inputDeviceUID: String {
        get { d.string(forKey: Key.inputDeviceUID) ?? "" }
        set { d.set(newValue, forKey: Key.inputDeviceUID) }
    }

    /// Name of that device, to label it in Preferences while it is disconnected.
    static var inputDeviceName: String {
        get { d.string(forKey: "inputDeviceName") ?? "" }
        set { d.set(newValue, forKey: "inputDeviceName") }
    }

    /// Mic noise suppression (default low).
    static var noiseSuppression: NoiseSuppression {
        d.string(forKey: Key.noiseSuppression).flatMap(NoiseSuppression.init(rawValue:)) ?? Default.noiseSuppression
    }

    /// Even out the mic level over the recording (WebRTC AGC2). Default off.
    static var autoLevel: Bool {
        d.object(forKey: Key.autoLevel) as? Bool ?? Default.autoLevel
    }

    /// Show the elapsed time next to the menu bar icon while recording (default on).
    static var showElapsedTime: Bool {
        d.object(forKey: Key.showElapsedTime) as? Bool ?? Default.showElapsedTime
    }

    /// Show the menu bar icon while idle (default on). While recording it is always shown.
    static var showMenuBarIcon: Bool {
        d.object(forKey: Key.showMenuBarIcon) as? Bool ?? Default.showMenuBarIcon
    }

    /// UI language (default: follow the system).
    static var language: AppLanguage {
        d.string(forKey: Key.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// Shell command run after each recording is saved, with the recording folder as $1
    /// (also in $MEEP_DIR). Empty = none.
    static var afterSaveCommand: String {
        d.string(forKey: Key.afterSaveCommand) ?? Default.afterSaveCommand
    }

    /// Reveal the recording in Finder once it has been saved (default on).
    static var openFolderAfterSaving: Bool {
        d.object(forKey: Key.openFolderAfterSaving) as? Bool ?? Default.openFolderAfterSaving
    }

    /// Skip the "track was silent the whole time" alert (set from the alert's "Don't show again").
    static var hideSilenceWarnings: Bool {
        get { d.bool(forKey: "hideSilenceWarnings") }
        set { d.set(newValue, forKey: "hideSilenceWarnings") }
    }

    /// Global start/stop hotkey. nil = disabled. Default ⌃⌘R.
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

    /// Launch at login via SMAppService. Registers this app bundle's current location.
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
    static var name: String { string("CFBundleDisplayName").isEmpty ? "Meep" : string("CFBundleDisplayName") }
    static var version: String { string("CFBundleShortVersionString") }
    static var build: String { string("CFBundleVersion") }
    static var copyright: String { string("NSHumanReadableCopyright") }
    static var privacyPolicyURL: URL? { URL(string: string("MRPrivacyPolicyURL")).flatMap { $0.scheme == nil ? nil : $0 } }
    static var termsOfUseURL: URL? { URL(string: string("MRTermsOfUseURL")).flatMap { $0.scheme == nil ? nil : $0 } }
    /// "owner/repo" whose GitHub Releases are the update source.
    static var updateRepo: String { string("MRUpdateGitHubRepo") }
}
