import AppKit
import CoreAudio
import Observation
import SwiftUI

/// Shared UI state for the preferences window. Views read it directly; Observation tracks access.
/// (No @State in views: the SwiftUI macro plugin ships only with full Xcode, not the CLT. The
/// Observation macros ship with the Swift toolchain, so @Observable works.)
@MainActor @Observable
final class AppState {
    var isRecording = false
    var launchAtLogin = AppSettings.launchAtLogin
    var loginError: String?
    var justCopied: String?

    // Hotkey
    var hotKey: Shortcut? = AppSettings.hotKey
    var isCapturingHotKey = false
    var hotKeyError: String?
    @ObservationIgnored private var keyMonitor: Any?

    // Updates
    enum UpdateStatus: Equatable, Sendable {
        case idle, checking, upToDate, available(version: String, url: URL), failed(String)
    }
    var update: UpdateStatus = .idle

    /// Called when a setting that affects the menu bar changes.
    @ObservationIgnored var onChange: () -> Void = {}

    // MARK: Audio sources

    /// Name of the system default input device; nil = none.
    var defaultInputName: String?
    /// Connected input devices, for the microphone picker.
    var inputDevices: [InputDevice] = []
    /// AppSettings.inputDeviceUID; "" = system default.
    var inputDeviceUID = AppSettings.inputDeviceUID
    /// Tells a running recording to switch devices.
    @ObservationIgnored var onInputDeviceChange: () -> Void = {}
    /// Whether the mic track would record the system default input (true also when the chosen
    /// device is the default, or is disconnected). Only then can Apple voice processing run.
    var recordsDefaultInput = true
    var micPermission = Permissions.microphone
    var systemAudioPermission = Permissions.systemAudio
    @ObservationIgnored private var deviceListener: HardwareListener?
    @ObservationIgnored private var activeObserver: Any?

    func refreshSources() {
        let defaultInput = try? defaultDevice(output: false)
        defaultInputName = defaultInput.flatMap(deviceName)
        inputDevices = listInputDevices()
        micPermission = Permissions.microphone
        systemAudioPermission = Permissions.systemAudio
        let target = preferredInputDevice()
        recordsDefaultInput = target == defaultInput
        // Follow the device the mic track would record from now (selection, default, plug-in),
        // and stop if mic access was revoked.
        if meterWanted, meter?.device != target || (meter != nil && micPermission != .authorized) {
            startMeter()
        }
    }

    // MARK: Recordings folder

    /// Shown in General › Saving; kept here so the view updates when it changes.
    var recordingsFolder = RecordingSession.rootDirectory
    var recordingsFolderError: String?

    /// Lets the user pick the folder new recordings are saved in. A recording in progress stays
    /// where it is (the button is disabled meanwhile).
    func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = recordingsFolder
        panel.prompt = tr("Choose")
        panel.message = tr("Choose where to save recordings.")
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            // A recording may have started while the panel was open; it must stay where it is.
            guard !self.isRecording else {
                self.recordingsFolderError = tr("Can't change while recording.")
                return
            }
            guard FileManager.default.isWritableFile(atPath: url.path) else {
                self.recordingsFolderError = tr("Can't save to %@: no write permission.", abbreviate(url.path))
                return
            }
            AppSettings.setRecordingsFolder(url)
            self.recordingsFolder = RecordingSession.rootDirectory
            self.recordingsFolderError = nil
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { r in MainActor.assumeIsolated { apply(r) } }
        } else {
            apply(panel.runModal())
        }
    }

    /// Which help popover is open (views keep no @State, see above); nil = none.
    var helpShown: String?

    // MARK: Input level meter

    /// Displayed input level, 0...1 (-60...0 dBFS, falls back slowly).
    var inputLevel: Float = 0
    @ObservationIgnored private var meter: InputLevelMeter?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var meterWanted = false

    /// Meters the mic track's input device while the Audio tab is visible. Opening the device
    /// turns on the mic indicator, so this runs only then, and only with mic access.
    func startMeter() {
        meterWanted = true
        stopMeterDevice()
        guard micPermission == .authorized, let dev = preferredInputDevice(),
              let m = InputLevelMeter(device: dev) else { return }
        meter = m
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickMeter() }  // runs on the main run loop
        }
        RunLoop.main.add(timer, forMode: .common)  // keeps ticking while a menu is open
        meterTimer = timer
    }

    func stopMeter() {
        meterWanted = false
        stopMeterDevice()
    }

    private func stopMeterDevice() {
        meterTimer?.invalidate(); meterTimer = nil
        meter?.stop(); meter = nil
        inputLevel = 0
    }

    private func tickMeter() {
        guard let meter else { return }
        let peak = meter.readPeak()
        let db = peak > 0 ? 20 * log10(peak) : -60
        let target = Float(max(0, min(1, (db + 60) / 60)))
        // Rise at once, fall ~1 unit per second. Assign only on change: every assignment
        // invalidates the views that read it.
        let next = max(target, inputLevel - 0.05)
        if next != inputLevel { inputLevel = next }
    }

    /// Keeps the sources current: default input changes, and permissions changed in System
    /// Settings (re-read when the app becomes active again).
    func watchSources() {
        refreshSources()
        guard deviceListener == nil else { return }
        deviceListener = HardwareListener(queue: .main, selectors: [
            kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices,
        ]) { [weak self] _ in MainActor.assumeIsolated { self?.refreshSources() } }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshSources() } }
    }

    func selectInputDevice(_ uid: String) {
        inputDeviceUID = uid
        AppSettings.inputDeviceUID = uid
        if let d = inputDevices.first(where: { $0.uid == uid }) { AppSettings.inputDeviceName = d.name }
        onInputDeviceChange()
        refreshSources()
    }

    /// Asks once; after a decision only System Settings can change it.
    func requestMicrophone() {
        guard micPermission == .notDetermined else {
            NSWorkspace.shared.open(Permissions.microphoneSettingsURL)
            return
        }
        Task {
            _ = await Permissions.requestMicrophone()
            refreshSources()
            if meterWanted { startMeter() }
        }
    }

    func requestSystemAudio() {
        guard systemAudioPermission == .notDetermined else {
            NSWorkspace.shared.open(Permissions.systemAudioSettingsURL)
            return
        }
        Task {
            _ = await Permissions.requestSystemAudio()
            refreshSources()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try AppSettings.setLaunchAtLogin(on)
            loginError = nil
        } catch {
            loginError = "\(error)"
        }
        launchAtLogin = AppSettings.launchAtLogin
    }

    func copy(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        justCopied = id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if justCopied == id { justCopied = nil }
        }
    }

    // MARK: Hotkey capture

    /// Next key press becomes the hotkey. Esc cancels, Delete clears.
    func beginHotKeyCapture() {
        guard !isCapturingHotKey else { return }
        isCapturingHotKey = true
        hotKeyError = nil
        GlobalHotKey.shared.unregister()  // so pressing the current combo is captured, not fired
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch Int(event.keyCode) {
            case 53:  // Esc
                self.endHotKeyCapture()
            case 51, 117:  // Delete, Forward Delete
                self.applyHotKey(nil)
            default:
                guard let s = Shortcut(event: event) else {
                    self.hotKeyError = tr("Use at least one of ⌘, ⌥ or ⌃.")
                    return nil
                }
                self.applyHotKey(s)
            }
            return nil
        }
    }

    func endHotKeyCapture() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        isCapturingHotKey = false
        GlobalHotKey.shared.register(AppSettings.hotKey)
    }

    private func applyHotKey(_ s: Shortcut?) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        isCapturingHotKey = false
        if GlobalHotKey.shared.register(s) {
            AppSettings.hotKey = s
            hotKey = s
            hotKeyError = nil
        } else {
            hotKeyError = tr("%@ is already used by another app.", s?.display ?? "")
            GlobalHotKey.shared.register(AppSettings.hotKey)  // keep the previous one
        }
    }

    // MARK: Update check (GitHub Releases)

    func checkForUpdate() {
        let repo = AppInfo.updateRepo
        guard !repo.isEmpty, let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            update = .failed(tr("No update source configured (MRUpdateGitHubRepo in Info.plist)."))
            return
        }
        update = .checking
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        Task {
            update = await Self.latestRelease(req, repo: repo)
        }
    }

    private nonisolated static func latestRelease(_ req: URLRequest, repo: String) async -> UpdateStatus {
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) } catch {
            return .failed(error.localizedDescription)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .failed(code == 404 ? tr("No releases found for %@.", repo) : tr("Unexpected response (HTTP %@).", code))
        }
        let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return latest.compare(AppInfo.version, options: .numeric) == .orderedDescending
            ? .available(version: latest, url: page) : .upToDate
    }
}

// MARK: - General

struct GeneralPreferencesView: View {
    let state: AppState
    @AppStorage(AppSettings.Key.language) private var language = AppLanguage.system.rawValue
    @AppStorage(AppSettings.Key.showMenuBarIcon) private var showMenuBarIcon = AppSettings.Default.showMenuBarIcon
    @AppStorage(AppSettings.Key.showElapsedTime) private var showElapsed = AppSettings.Default.showElapsedTime
    @AppStorage(AppSettings.Key.openFolderAfterSaving) private var openFolderAfterSaving = AppSettings.Default.openFolderAfterSaving

    var body: some View {
        Form {
            Section(tr("Launch")) {
                Toggle(tr("Start at Login"), isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }))
                if let e = state.loginError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
                LabeledContent(tr("Hotkey")) {
                    Button {
                        state.isCapturingHotKey ? state.endHotKeyCapture() : state.beginHotKeyCapture()
                    } label: {
                        Text(state.isCapturingHotKey ? tr("Press shortcut…")
                                                     : (state.hotKey?.display ?? tr("None")))
                            .frame(minWidth: 110)
                    }
                    .help(tr("Start or stop recording from anywhere. Click, then press a new shortcut."))
                }
                if let e = state.hotKeyError {
                    Text(e).font(.caption).foregroundStyle(.red)
                } else if state.isCapturingHotKey {
                    Text(tr("Esc to cancel · Delete to clear"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(tr("Appearance")) {
                Picker(tr("Language"), selection: $language) {
                    ForEach(AppLanguage.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Toggle(tr("Show Menu Bar Icon"), isOn: $showMenuBarIcon)
                if !showMenuBarIcon {
                    Text(tr("The icon still appears while recording. Open the app again to show this window."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(tr("Show Recording Time"), isOn: $showElapsed)
            }

            Section(tr("Saving")) {
                Toggle(tr("Open Folder After Saving"), isOn: $openFolderAfterSaving)
                LabeledContent {
                    HStack {
                        Button(tr("Change…"), action: state.chooseRecordingsFolder)
                            .disabled(state.isRecording || AppSettings.recordingsFolderFromEnvironment)
                        Button(tr("Show in Finder"), action: RecordingSession.revealRootDirectory)
                    }
                } label: {
                    Text(tr("Recordings Folder"))
                    Text(abbreviate(state.recordingsFolder.path))  // rendered as a subtitle
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(abbreviate(state.recordingsFolder.path))
                }
                if let e = state.recordingsFolderError {
                    Text(e).font(.caption).foregroundStyle(.red)
                } else if AppSettings.recordingsFolderFromEnvironment {
                    Text(tr("Set by MEEP_ROOT.")).font(.caption).foregroundStyle(.secondary)
                } else if state.isRecording {
                    Text(tr("Can't change while recording.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize()
        .onAppear {
            state.launchAtLogin = AppSettings.launchAtLogin
            state.recordingsFolder = RecordingSession.rootDirectory  // may be set with `defaults`
        }
        .onDisappear { if state.isCapturingHotKey { state.endHotKeyCapture() } }
        .onChange(of: language) { _, _ in state.onChange() }
        .onChange(of: showMenuBarIcon) { _, _ in state.onChange() }
        .onChange(of: showElapsed) { _, _ in state.onChange() }
    }
}

// MARK: - Audio

/// Per source (microphone, system audio): access and what is recorded; then post-processing.
struct AudioPreferencesView: View {
    let state: AppState
    @AppStorage(AppSettings.Key.language) private var language = AppLanguage.system.rawValue
    @AppStorage(AppSettings.Key.echoCancellation) private var echoRaw = AppSettings.Default.echoMode.rawValue
    @AppStorage(AppSettings.Key.recordSystemAudio) private var recordSystemAudio = AppSettings.Default.recordSystemAudio
    @AppStorage(AppSettings.Key.noiseSuppression) private var noiseRaw = AppSettings.Default.noiseSuppression.rawValue
    @AppStorage(AppSettings.Key.autoLevel) private var autoLevel = AppSettings.Default.autoLevel

    var body: some View {
        Form {
            Section(tr("Microphone")) {
                permissionRow(tr("Access"), status: state.micPermission, request: state.requestMicrophone)
                Picker(tr("Input Device"), selection: Binding(
                    get: { state.inputDeviceUID }, set: { state.selectInputDevice($0) })) {
                    Text(state.defaultInputName.map { tr("System Default (%@)", $0) } ?? tr("System Default"))
                        .tag("")
                    Divider()
                    ForEach(state.inputDevices, id: \.uid) { Text($0.name).tag($0.uid) }
                    if !state.inputDeviceUID.isEmpty,
                       !state.inputDevices.contains(where: { $0.uid == state.inputDeviceUID }) {
                        Text(tr("%@ (not connected)", AppSettings.inputDeviceName.isEmpty
                                ? state.inputDeviceUID : AppSettings.inputDeviceName))
                            .tag(state.inputDeviceUID)
                    }
                }
                if state.micPermission == .authorized {
                    InputLevelRow(state: state)  // its own view: only it redraws as the level moves
                }
            }

            Section(tr("System Audio")) {
                permissionRow(tr("Access"), status: state.systemAudioPermission, request: state.requestSystemAudio)
                Toggle(isOn: $recordSystemAudio) {
                    Text(tr("Record"))
                    if state.isRecording { Text(tr("Can't change while recording.")) }  // rendered as a subtitle
                }
                .disabled(state.isRecording)
            }

            Section {
                Picker(selection: $echoRaw) {
                    ForEach(EchoMode.allCases, id: \.rawValue) { Text($0.shortTitle).tag($0.rawValue) }
                } label: {
                    HStack(spacing: 6) {
                        Text(tr("Echo Cancellation"))
                        HelpButton(state: state, id: "echoCancellation", paragraphs: [
                            tr("Removes the speaker sound your microphone picks up. Not needed with headphones."),
                            tr("WebRTC: better quality. Apple: works live, but turns other apps down."),
                        ])
                    }
                    // Rendered as a subtitle.
                    if state.isRecording {
                        Text(tr("Can't change while recording."))
                    } else if !recordSystemAudio {
                        Text(tr("Needs system audio recording."))
                    }
                }
                .disabled(state.isRecording || !recordSystemAudio)
                Picker(selection: $noiseRaw) {
                    ForEach(NoiseSuppression.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                } label: {
                    HStack(spacing: 6) {
                        Text(tr("Noise Suppression"))
                        HelpButton(state: state, id: "noiseSuppression", paragraphs: [
                            tr("Removes steady background noise, like fans or air conditioning."),
                            tr("Higher levels remove more, but your voice may sound muffled. Low is fine for most rooms."),
                        ])
                    }
                    micProcessingNote
                }
                .disabled(state.isRecording || appleProcessesMic)
                Toggle(isOn: $autoLevel) {
                    HStack(spacing: 6) {
                        Text(tr("Auto Level"))
                        HelpButton(state: state, id: "autoLevel", paragraphs: [
                            tr("Keeps your voice at a steady volume."),
                            tr("Background noise gets louder too. Leave it off if your volume is already fine."),
                        ])
                    }
                    micProcessingNote
                }
                .disabled(state.isRecording || appleProcessesMic)
            } header: {
                Text(tr("Post-Processing"))
            } footer: {
                HStack {
                    Spacer()
                    Button(tr("Restore Defaults"), action: restoreDefaults)
                        .disabled(state.isRecording || isDefault)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize()
        .onAppear {
            state.watchSources()
            state.startMeter()
        }
        .onDisappear { state.stopMeter() }
        .onChange(of: echoRaw) { _, _ in state.onChange() }
    }

    private typealias Default = AppSettings.Default

    private var isDefault: Bool {
        state.inputDeviceUID.isEmpty && recordSystemAudio == Default.recordSystemAudio
            && echoRaw == Default.echoMode.rawValue && noiseRaw == Default.noiseSuppression.rawValue
            && autoLevel == Default.autoLevel
    }

    private func restoreDefaults() {
        if !state.inputDeviceUID.isEmpty { state.selectInputDevice("") }
        recordSystemAudio = Default.recordSystemAudio
        echoRaw = Default.echoMode.rawValue
        noiseRaw = Default.noiseSuppression.rawValue
        autoLevel = Default.autoLevel
    }

    /// Apple voice processing does its own noise suppression and gain; it runs with system audio
    /// on and the system default input (see MicRecorder).
    private var appleProcessesMic: Bool {
        echoRaw == EchoMode.apple.rawValue && recordSystemAudio && state.recordsDefaultInput
    }

    @ViewBuilder private var micProcessingNote: some View {
        if state.isRecording {
            Text(tr("Can't change while recording."))
        } else if appleProcessesMic {
            Text(tr("Handled by Apple Voice Processing."))
        }
    }

    private func permissionRow(_ title: String, status: PermissionStatus,
                               request: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            switch status {
            case .authorized:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(tr("Allowed")).foregroundStyle(.secondary)
                }
            case .notDetermined:
                Button(tr("Allow Access"), action: request)
            case .denied:
                HStack(spacing: 8) {
                    Text(tr("Not Allowed")).foregroundStyle(.red)
                    Button(tr("Open System Settings"), action: request)
                }
            case .unknown:
                Button(tr("Open System Settings"), action: request)
            }
        }
    }
}

// MARK: - Agent

/// Everything an AI agent or a script needs: how to drive the app and where results go.
struct AgentPreferencesView: View {
    let state: AppState
    @AppStorage(AppSettings.Key.language) private var language = AppLanguage.system.rawValue
    @AppStorage(AppSettings.Key.afterSaveCommand) private var afterSaveCommand = AppSettings.Default.afterSaveCommand

    static let urls = ["meep://start", "meep://stop", "meep://preferences"]
    private var helpCommand: String { "\"\(Bundle.main.executableURL?.path ?? "Meep")\" --help" }

    var body: some View {
        Form {
            Section {
                Text(tr("Agents and scripts can start and stop recording with the URLs below, check progress with the status command, and read the results from the recordings folder: mixed.m4a, plus the separate tracks and session.json in raw/."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("URL Scheme") {
                ForEach(Self.urls, id: \.self) { url in
                    copyRow(url, copyText: "open \"\(url)\"")
                }
            }

            Section(tr("Command Line")) {
                copyRow(helpCommand, copyText: helpCommand, wrap: true)
            }

            Section {
                TextField(tr("Run After Saving"), text: $afterSaveCommand,
                          prompt: Text(verbatim: "~/bin/transcribe"))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text(tr("Run After Saving"))
            } footer: {
                Text(tr("A shell command run after each recording is saved. It gets the recording folder as $1 and in $MEEP_DIR. Output goes to raw/after-save.log."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize()
    }

    private func copyRow(_ code: String, copyText: String, wrap: Bool = false) -> some View {
        HStack {
            Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: false, vertical: wrap)
            Spacer()
            Button {
                state.copy(copyText, id: code)
            } label: {
                Image(systemName: state.justCopied == code ? "checkmark" : "doc.on.doc").frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(tr("Copy: ") + copyText)
        }
    }
}

// MARK: - About

struct AboutPreferencesView: View {
    let state: AppState
    @AppStorage(AppSettings.Key.language) private var language = AppLanguage.system.rawValue

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.top, 24)
            Text(AppInfo.name)
                .font(.title2.weight(.semibold))
                .padding(.top, 10)
            Text(tr("Version") + " \(AppInfo.version) (\(AppInfo.build))")
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)

            HStack(spacing: 24) {
                link(tr("Privacy Policy"), AppInfo.privacyPolicyURL)
                link(tr("Terms of Use"), AppInfo.termsOfUseURL)
            }
            .padding(.top, 18)

            Text(AppInfo.copyright)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 10)

            Button(action: state.checkForUpdate) {
                Text(state.update == .checking ? tr("Checking…") : tr("Check for Updates"))
                    .frame(minWidth: 140)
            }
            .disabled(state.update == .checking)
            .padding(.top, 18)
            updateStatus
                .font(.caption)
                .multilineTextAlignment(.center)
                .frame(height: 32, alignment: .top)
                .padding(.top, 6)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(width: 460)
        .fixedSize()
    }

    @ViewBuilder private var updateStatus: some View {
        switch state.update {
        case .idle, .checking: Text(" ")
        case .upToDate: Text(tr("You're up to date.")).foregroundStyle(.secondary)
        case .available(let v, let url):
            HStack(spacing: 4) {
                Text(tr("Version %@ is available.", v)).foregroundStyle(.secondary)
                Link(tr("Download"), destination: url)
            }
        case .failed(let msg): Text(msg).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func link(_ title: String, _ url: URL?) -> some View {
        if let url {
            Link(title, destination: url)
        } else {
            Text(title).foregroundStyle(.tertiary).help(tr("Not configured yet"))
        }
    }
}

private func abbreviate(_ path: String) -> String {
    path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

// MARK: - Window

/// A single reusable preferences window with toolbar tabs (General / Audio / Agent / About).
@MainActor
final class PreferencesWindowController: NSWindowController {
    private var state: AppState?
    private var closeObserver: Any?
    private var resignObserver: Any?

    enum Tab: Int, CaseIterable {
        case general, audio, agent, about

        var label: String {
            switch self {
            case .general: return tr("General")
            case .audio: return tr("Audio")
            case .agent: return "Agent"
            case .about: return tr("About")
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .audio: return "waveform"
            case .agent: return "terminal"
            case .about: return "info.circle"
            }
        }
    }

    convenience init(state: AppState) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true

        func host<V: View>(_ view: V, _ tab: Tab) -> NSTabViewItem {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = .preferredContentSize  // window resizes to each tab
            let item = NSTabViewItem(viewController: host)
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
            return item
        }
        tabs.addTabViewItem(host(GeneralPreferencesView(state: state), .general))
        tabs.addTabViewItem(host(AudioPreferencesView(state: state), .audio))
        tabs.addTabViewItem(host(AgentPreferencesView(state: state), .agent))
        tabs.addTabViewItem(host(AboutPreferencesView(state: state), .about))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        self.init(window: window)
        self.state = state
        // The level meter keeps the mic open, and hotkey capture keeps the global hotkey off:
        // end both when the window closes (SwiftUI's onDisappear does not fire for that).
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                state.stopMeter()
                if state.isCapturingHotKey { state.endHotKeyCapture() }
            }
        }
        // Capture also ends when the user switches to another app mid-way.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { if state.isCapturingHotKey { state.endHotKeyCapture() } } }
        relabel()
    }

    /// Applies the current language to tab labels and the window title.
    func relabel() {
        guard let tabs = contentViewController as? NSTabViewController else { return }
        for (item, tab) in zip(tabs.tabViewItems, Tab.allCases) {
            item.label = tab.label
            item.viewController?.title = tab.label  // propagated to the window title
        }
        window?.title = Tab(rawValue: tabs.selectedTabViewItemIndex)?.label ?? ""
    }

    func show(tab: Tab? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let reopening = window?.isVisible == false
        if reopening { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        // Select after the window (and the tab view) has loaded; selecting earlier gets reset.
        guard let tabs = contentViewController as? NSTabViewController else { return }
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
        // Reopened on the Audio tab: its view did not reappear, so restart the meter here.
        if reopening, tabs.selectedTabViewItemIndex == Tab.audio.rawValue { state?.startMeter() }
    }
}

extension NoiseSuppression {
    var title: String {
        switch self {
        case .off: return tr("Off")
        case .low: return tr("Low")
        case .moderate: return tr("Moderate")
        case .high: return tr("High")
        case .veryHigh: return tr("Very High")
        }
    }
}

/// A "?" button showing a popover: the first paragraph says what a setting does, the others
/// (secondary) its costs and when to use it.
struct HelpButton: View {
    let state: AppState
    let id: String
    let paragraphs: [String]

    var body: some View {
        HelpLink { state.helpShown = state.helpShown == id ? nil : id }
            .controlSize(.mini)
            .popover(isPresented: Binding(get: { state.helpShown == id },
                                          set: { if !$0, state.helpShown == id { state.helpShown = nil } }),
                     arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { i, text in
                        Text(text).foregroundStyle(i == 0 ? .primary : .secondary)
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(14)
            }
    }
}

struct InputLevelRow: View {
    let state: AppState
    var body: some View {
        LabeledContent(tr("Input Level")) { LevelBar(level: state.inputLevel) }
    }
}

/// Horizontal input level meter (-60...0 dBFS).
struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.9 ? Color.red : (level > 0.75 ? Color.yellow : Color.green))
                    .frame(width: geo.size.width * CGFloat(level))
            }
        }
        .frame(width: 180, height: 6)
        .accessibilityValue(Text(verbatim: "\(Int(level * 60 - 60)) dB"))
    }
}

extension EchoMode {
    var shortTitle: String {
        switch self {
        case .off: return tr("Off")
        case .apple: return tr("Apple Voice Processing")
        case .webrtc: return "WebRTC AEC3"
        }
    }
}
