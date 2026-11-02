import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var healthItem: NSMenuItem!
    private var folderItem: NSMenuItem!
    private var prefsItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var session: RecordingSession?
    private var timer: Timer?
    private var starting = false
    private var stopping = false
    /// Processing progress 0...1 (after Stop, or finishing an unfinished recording at launch).
    private var progress: Double?
    private var recoveringPrevious = false
    private var progressItem: NSMenuItem!
    private let progressBar = NSProgressIndicator()
    private var launched = false
    private var pendingCommand: String?
    private let appState = AppState()
    private lazy var preferences = PreferencesWindowController(state: appState)

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register before launch completes, so a URL that launched the app is not missed.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:_:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false

        toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(toggleItem)
        healthItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        healthItem.isEnabled = false
        healthItem.isHidden = true
        menu.addItem(healthItem)
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        let barView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 18))
        progressBar.frame = NSRect(x: 20, y: 3, width: 200, height: 12)
        progressBar.autoresizingMask = [.width]
        barView.addSubview(progressBar)
        progressItem = NSMenuItem()
        progressItem.view = barView
        progressItem.isHidden = true
        menu.addItem(progressItem)
        folderItem = NSMenuItem(title: "", action: #selector(openFolder), keyEquivalent: "o")
        menu.addItem(folderItem)
        menu.addItem(.separator())
        prefsItem = NSMenuItem(title: "", action: #selector(showPreferences), keyEquivalent: ",")
        menu.addItem(prefsItem)
        menu.addItem(.separator())
        quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
        appState.onInputDeviceChange = { [weak self] in self?.session?.inputDeviceSettingChanged() }
        appState.onChange = { [weak self] in
            self?.updateUI()
            self?.preferences.relabel()  // tab names follow the language setting
        }

        // Global start/stop hotkey (default ⌘⇧R).
        GlobalHotKey.shared.action = { [weak self] in self?.toggle() }
        GlobalHotKey.shared.register(AppSettings.hotKey)
        updateUI()

        launched = true
        recoverUnfinishedSessions()
        if let cmd = pendingCommand {
            pendingCommand = nil
            run(command: cmd)
        } else {
            Task { _ = await micPermission() }
        }
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows Preferences: the only way back
    /// in when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        preferences.show()
        return true
    }

    // MARK: - Menu

    @objc private func showPreferences() {
        preferences.show()
    }

    /// Finishes recordings left unfinished by a crash, or by Quit / shutdown during processing.
    private func recoverUnfinishedSessions() {
        let root = RecordingSession.rootDirectory
        let report = progressReporter(recovering: true)
        Task {
            let dirs = await Task.detached(priority: .utility) {
                let dirs = Finalizer.recoverUnfinished(root: root, progress: report)
                dirs.forEach(AfterSaveHook.run)
                return dirs
            }.value
            recoveringPrevious = false
            if !stopping { progress = nil }
            updateUI()
            guard !dirs.isEmpty else { return }
            alert(tr("Finished unfinished recordings"),
                  tr("These recordings were not finished last time (the app quit or the Mac shut down). They are processed and saved now:") + "\n\n"
                  + dirs.map(\.lastPathComponent).joined(separator: "\n"))
        }
    }

    /// A progress callback for processing threads. Hops to the main queue in order (a Task per
    /// call could arrive out of order), then updates the menu when the whole percent changes.
    private nonisolated func progressReporter(recovering: Bool) -> @Sendable (Double) -> Void {
        { f in DispatchQueue.main.async { self.setProgress(f, recovering: recovering) } }
    }

    private func setProgress(_ f: Double, recovering: Bool) {
        if recovering {
            recoveringPrevious = true
            if stopping { return }  // the current recording's progress wins
        }
        let old = progress.map { Int($0 * 100) }
        progress = f
        if old != Int(f * 100) { updateUI() }
    }

    // MARK: - Recording

    @objc private func handleURL(_ event: NSAppleEventDescriptor, _ reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s), let host = url.host else { return }
        // URL scheme: meetingrecorder://start|stop|preferences[/general|/agent|/about]
        let command = host + url.path
        if launched { run(command: command) } else { pendingCommand = command }
    }

    private func run(command host: String) {
        switch host {
        case "start": if session == nil { toggle() }
        case "stop": if session != nil { toggle() }
        case "preferences": preferences.show()
        case "preferences/general": preferences.show(tab: .general)
        case "preferences/audio": preferences.show(tab: .audio)
        case "preferences/agent": preferences.show(tab: .agent)
        case "preferences/about": preferences.show(tab: .about)
        default: break
        }
    }

    @objc private func toggle() {
        if starting || stopping { return }
        if let s = session { stop(s) } else { start() }
    }

    private func start() {
        starting = true  // the permission prompt can take a while; ignore toggles until it is done
        Task {
            defer { starting = false }
            if !(await micPermission()) {
                alert(tr("No microphone access"),
                      tr("Allow MeetingRecorder in System Settings › Privacy & Security › Microphone. This recording captures system audio only."),
                      settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            }
            do {
                let s = try RecordingSession()
                try s.start()
                session = s
                startTimer()
            } catch {
                alert(tr("Can't start recording"), "\(error)")
            }
            updateUI()
        }
    }

    /// Ticks the elapsed time in the menu bar once a second.
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateUI() }  // scheduled on the main run loop
        }
    }

    private func stop(_ s: RecordingSession) {
        stopping = true
        progress = 0
        timer?.invalidate(); timer = nil
        updateUI()
        let report = progressReporter(recovering: false)
        Task {
            let warnings = await Task.detached(priority: .userInitiated) {
                let warnings = s.stop(progress: report)
                AfterSaveHook.run(s.directory)
                return warnings
            }.value
            session = nil
            stopping = false
            progress = nil
            updateUI()
            // Silence warnings can be muted; real failures (write errors, lost tracks) always show.
            let shown = AppSettings.hideSilenceWarnings
                ? warnings.filter { !s.silenceWarnings.contains($0) } : warnings
            if !shown.isEmpty {
                let canSuppress = shown.contains { s.silenceWarnings.contains($0) }
                let suppressed = alert(tr("Recording saved with warnings"), shown.joined(separator: "\n\n"),
                                       settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
                                       suppressible: canSuppress)
                if suppressed { AppSettings.hideSilenceWarnings = true }
            }
            if AppSettings.openFolderAfterSaving {
                // Select the mix (what most people want); fall back to the folder.
                let mixed = s.directory.appendingPathComponent("mixed.m4a")
                let target = FileManager.default.fileExists(atPath: mixed.path) ? mixed : s.directory
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
        }
    }

    private func updateUI() {
        guard let button = statusItem?.button else { return }
        let recording = session != nil || stopping || recoveringPrevious
        if appState.isRecording != recording { appState.isRecording = recording }
        // Hidden while idle if the user turned the icon off; always shown while recording/saving.
        statusItem.isVisible = AppSettings.showMenuBarIcon || recording
        // Show the global hotkey on the start/stop item.
        if let hk = AppSettings.hotKey, hk.keyLabel.count == 1 {
            toggleItem.keyEquivalent = hk.keyLabel.lowercased()
            toggleItem.keyEquivalentModifierMask = hk.modifiers
        } else {
            toggleItem.keyEquivalent = ""
        }
        healthItem.isHidden = true
        progressItem.isHidden = true
        let percent = progress.map { "\(Int($0 * 100))%" } ?? ""
        folderItem.title = tr("Open Recordings Folder")
        prefsItem.title = tr("Open Preferences…")
        quitItem.title = tr("Quit")
        var icon = MenuBarIcons.idle
        var label = ""
        if stopping {
            icon = MenuBarIcons.saving
            toggleItem.title = tr("Saving… %@", percent)
            toggleItem.isEnabled = false
            label = percent
            button.toolTip = "MeetingRecorder: " + tr("saving") + " \(percent)"
        } else if let s = session {
            let elapsed = RecordingSession.clock(Date().timeIntervalSince(s.startedAt))
            toggleItem.title = tr("Stop Recording (%@)", elapsed)
            toggleItem.isEnabled = true
            icon = MenuBarIcons.recording
            if AppSettings.showElapsedTime { label = elapsed }
            switch s.health {
            case .ok:
                break
            case .recovering(let t):
                icon = MenuBarIcons.recovering
                healthItem.title = t == .mic ? tr("Recovering microphone…")
                                             : tr("Recovering system audio…")
                healthItem.isHidden = false
            case .lost(let t):
                icon = MenuBarIcons.recovering
                healthItem.title = "⚠️ " + (t == .mic ? tr("Microphone lost, retrying")
                                                     : tr("System audio lost, retrying"))
                healthItem.isHidden = false
            }
            button.toolTip = "MeetingRecorder: " + tr("recording") + " \(elapsed)"
        } else {
            toggleItem.title = tr("Start Recording")
            toggleItem.isEnabled = true
            button.toolTip = "MeetingRecorder"
            if recoveringPrevious {
                icon = MenuBarIcons.saving
                label = percent
                healthItem.title = tr("Finishing an unfinished recording… %@", percent)
                healthItem.isHidden = false
            }
        }
        if let p = progress, stopping || (session == nil && recoveringPrevious) {
            progressBar.doubleValue = p
            progressItem.isHidden = false
        }
        button.image = icon
        button.imagePosition = label.isEmpty ? .imageOnly : .imageLeading
        // Monospaced digits so the item does not jitter as the seconds tick.
        button.attributedTitle = NSAttributedString(string: label.isEmpty ? "" : " " + label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
        if icon == nil { button.title = stopping ? "⏳" : (session != nil ? "🔴 " + label : "🎙") }  // assets missing
    }

    /// Asks for microphone access the first time; afterwards returns the stored decision.
    private func micPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    @objc private func openFolder() {
        let root = RecordingSession.rootDirectory
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Quit, logout or shutdown: close the capture files and exit right away. Processing (AEC,
    /// mix, AAC) is not waited for; it runs on the next launch (see recoverUnfinishedSessions).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        session?.stopCapture()
        Subprocesses.terminateAll()
        return .terminateNow
    }

    /// Returns true if the user ticked "Don't show again" (only offered when `suppressible`).
    @discardableResult
    private func alert(_ title: String, _ text: String, settingsURL: String? = nil, suppressible: Bool = false) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: tr("OK"))
        if settingsURL != nil { a.addButton(withTitle: tr("Open System Settings")) }
        if suppressible {
            a.showsSuppressionButton = true
            a.suppressionButton?.title = tr("Don't show again")
        }
        if a.runModal() == .alertSecondButtonReturn, let u = settingsURL, let url = URL(string: u) {
            NSWorkspace.shared.open(url)
        }
        return suppressible && a.suppressionButton?.state == .on
    }
}

// MARK: - CLI (see CLI.swift; anything that is not a CLI invocation launches the menu bar app)

let cliArguments = Array(CommandLine.arguments.dropFirst())
if CLI.isInvocation(cliArguments) { CLI.main(cliArguments) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
