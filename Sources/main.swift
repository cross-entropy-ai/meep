import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var healthItem: NSMenuItem!
    private var folderItem: NSMenuItem!
    private var prefsItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var timer: Timer?

    /// The current recording. Stopped recordings are processed separately (`saving`), so the
    /// next one can start meanwhile.
    private enum Capture {
        case idle
        /// Permission prompts and starting the capture; can take a while.
        case starting
        case recording(RecordingSession)
        /// Closing the capture files (brief).
        case stopping(RecordingSession)

        var session: RecordingSession? {
            switch self {
            case .recording(let s), .stopping(let s): s
            case .idle, .starting: nil
            }
        }
        /// Starting or stopping: a new request waits in `pending`.
        var isBusy: Bool {
            switch self {
            case .starting, .stopping: true
            case .idle, .recording: false
            }
        }
        /// Where it ends up once the current start/stop is done.
        var isOn: Bool {
            switch self {
            case .starting, .recording: true
            case .idle, .stopping: false
            }
        }
    }
    private var capture = Capture.idle
    /// Start (true) or stop (false) asked for while starting or stopping; applied when that ends,
    /// so a quick `stop` + `start` from a script or the hotkey is not lost.
    private var pending: (recording: Bool, quiet: Bool)?
    /// Stopped recordings still being processed (echo cancellation, mix, encoding).
    private var saving = 0
    /// Finishing recordings left unfinished last time (at launch).
    private var recoveringPrevious = false
    /// Processing progress 0...1 (after Stop, or finishing an unfinished recording at launch).
    private var progress: Double?
    private var progressItem: NSMenuItem!
    private let progressBar = NSProgressIndicator()
    private var launched = false
    /// A URL command received before launch finished; run once it has.
    private var queuedCommand: (command: String, quiet: Bool)?
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
        updateItem = NSMenuItem(title: "", action: #selector(openUpdate), keyEquivalent: "")
        updateItem.isHidden = true
        menu.addItem(updateItem)
        prefsItem = NSMenuItem(title: "", action: #selector(showPreferences), keyEquivalent: ",")
        menu.addItem(prefsItem)
        menu.addItem(.separator())
        quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
        appState.onInputDeviceChange = { [weak self] in self?.capture.session?.inputDeviceSettingChanged() }
        appState.onChange = { [weak self] in
            self?.updateUI()
            self?.preferences.relabel()  // tab names follow the language setting
        }

        // Global start/stop hotkey (default ⌃⌘R).
        GlobalHotKey.shared.action = { [weak self] in self?.toggle() }
        GlobalHotKey.shared.register(AppSettings.hotKey)
        updateUI()

        // Updates (Sparkle): an install waits until recording and saving are done.
        appState.updates.isBusy = { [weak self] in self?.appState.isRecording ?? false }
        appState.updates.onChange = { [weak self] in self?.updateUI() }
        appState.updates.start()

        launched = true
        // Launched by a quiet URL (the CLI): no alert about recovered recordings either.
        recoverUnfinishedSessions(quiet: queuedCommand?.quiet ?? false)
        if let cmd = queuedCommand {
            queuedCommand = nil
            run(command: cmd.command, quiet: cmd.quiet)
        } else {
            Task { await askForAccess() }
        }
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows Preferences: the only way back
    /// in when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        preferences.show()
        return true
    }

    // MARK: - Menu

    /// Shows the update a scheduled check found.
    @objc private func openUpdate() {
        appState.updates.checkForUpdates()
    }

    @objc private func showPreferences() {
        preferences.show()
    }

    /// Finishes recordings left unfinished by a crash, or by Quit / shutdown during processing.
    private func recoverUnfinishedSessions(quiet: Bool) {
        let root = RecordingSession.rootDirectory
        let report = progressReporter(recovering: true)
        Task {
            let dirs = await Task.detached(priority: .utility) {
                let dirs = Finalizer.recoverUnfinished(root: root, progress: report)
                dirs.forEach(AfterSaveHook.run)
                return dirs
            }.value
            recoveringPrevious = false
            if saving == 0 { progress = nil }
            updateUI()
            guard !dirs.isEmpty, !quiet else { return }
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
            if saving > 0 { return }  // the current recording's progress wins
        }
        let old = progress.map { Int($0 * 100) }
        progress = f
        if old != Int(f * 100) { updateUI() }
    }

    // MARK: - Recording

    @objc private func handleURL(_ event: NSAppleEventDescriptor, _ reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s), let host = url.host else { return }
        // URL scheme: meep://start|stop|preferences[/general|/audio|/agent|/about]
        // `?quiet` (the CLI adds it): no alerts and no Finder window for that recording; outcomes
        // are in session.json and last-start.json instead, for scripts that nobody watches.
        let command = host + (url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path)
        let quiet = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == "quiet" } ?? false
        if launched { run(command: command, quiet: quiet) } else { queuedCommand = (command, quiet) }
    }

    private func run(command host: String, quiet: Bool) {
        switch host {
        case "start": request(recording: true, quiet: quiet)
        case "stop": request(recording: false, quiet: quiet)
        case "preferences": preferences.show()
        case "preferences/general": preferences.show(tab: .general)
        case "preferences/audio": preferences.show(tab: .audio)
        case "preferences/agent": preferences.show(tab: .agent)
        case "preferences/about": preferences.show(tab: .about)
        default: NSLog("Meep: unknown URL command %@", host)
        }
    }

    @objc private func toggle() {
        // While busy, toggle relative to where the current start/stop (or a pending one) ends up.
        request(recording: !(pending?.recording ?? capture.isOn))
    }

    private func request(recording want: Bool, quiet: Bool = false) {
        if capture.isBusy {
            pending = (want, quiet)
            return
        }
        pending = nil  // acting now supersedes anything queued
        switch capture {
        case .idle where want: start(quiet: quiet)
        case .recording(let s) where !want: stop(s, quiet: quiet)
        default: break
        }
    }

    private func applyPendingRequest() {
        guard let p = pending else { return }
        pending = nil
        request(recording: p.recording, quiet: p.quiet)
    }

    private func start(quiet: Bool) {
        capture = .starting
        Task {
            let micAllowed = await micPermission()
            if AppSettings.recordSystemAudio { await systemAudioPermission() }
            var failure: String?
            if !micAllowed && !AppSettings.recordSystemAudio {
                failure = tr("No microphone access, and system audio recording is off: there is nothing to record.")
            } else {
                do {
                    let s = try RecordingSession()
                    s.quiet = quiet
                    try s.start()
                    capture = .recording(s)
                    startTimer()
                } catch {
                    failure = (error as? CAError)?.description ?? error.localizedDescription
                }
            }
            if let failure {
                StartFailure.record(failure)  // for `start --wait`
                capture = .idle
            }
            updateUI()
            // A stop asked for meanwhile runs now, before the alerts below (which block).
            applyPendingRequest()
            // Alerts only after capture is running (or has failed): they block until dismissed.
            if quiet {
                // A script started this: the outcome is in session.json / last-start.json.
            } else if let failure {
                alert(tr("Can't start recording"), failure,
                      settingsURL: micAllowed ? nil : Permissions.microphoneSettingsURL.absoluteString)
            } else if !micAllowed {
                alert(tr("No microphone access"),
                      tr("Allow Meep in System Settings › Privacy & Security › Microphone. This recording captures system audio only."),
                      settingsURL: Permissions.microphoneSettingsURL.absoluteString)
            }
        }
    }

    /// Ticks the elapsed time in the menu bar once a second.
    private func startTimer() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateUI() }  // runs on the main run loop
        }
        RunLoop.main.add(t, forMode: .common)  // keeps ticking while the menu or an alert is open
        timer = t
    }

    private func stop(_ s: RecordingSession, quiet: Bool = false) {
        let quiet = quiet || s.quiet
        capture = .stopping(s)
        timer?.invalidate(); timer = nil
        updateUI()
        let report = progressReporter(recovering: false)
        Task {
            // 1. Stop capture (fast). From here a new recording can start, e.g. the next meeting
            //    right away, while this one is processed.
            await Task.detached(priority: .userInitiated) { s.stopCapture() }.value
            capture = .idle
            saving += 1
            progress = 0
            updateUI()
            applyPendingRequest()
            // 2. Process: echo cancellation, mix, encoding. Minutes for a long meeting.
            let warnings = await Task.detached(priority: .userInitiated) {
                let warnings = s.process(progress: report)
                AfterSaveHook.run(s.directory)
                return warnings
            }.value
            saving -= 1
            if saving == 0 { progress = nil }
            updateUI()
            // A script started or stopped this one: warnings are in session.json, no Finder.
            if quiet { return }
            // Silence warnings can be muted; real failures (write errors, lost tracks) always show.
            let shown = AppSettings.hideSilenceWarnings
                ? warnings.filter { !s.silenceWarnings.contains($0) } : warnings
            if !shown.isEmpty {
                let canSuppress = shown.contains { s.silenceWarnings.contains($0) }
                let suppressed = alert(tr("Recording saved with warnings"), shown.joined(separator: "\n\n"),
                                       settingsURL: Permissions.systemAudioSettingsURL.absoluteString,
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
        let recording = capture.session != nil || saving > 0 || recoveringPrevious
        if appState.isRecording != recording {
            appState.isRecording = recording
            if !recording { appState.updates.idle() }
        }
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
        if let v = appState.updates.pendingVersion {
            updateItem.title = tr("Update Available: %@", v)
            updateItem.isHidden = false
        } else {
            updateItem.isHidden = true
        }
        quitItem.title = tr("Quit")
        var icon = MenuBarIcons.idle
        var label = ""
        switch capture {
        case .stopping:
            icon = MenuBarIcons.saving
            toggleItem.title = tr("Saving… %@", percent)
            toggleItem.isEnabled = false
            button.toolTip = "Meep: " + tr("saving")
        case .recording(let s):
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
            button.toolTip = "Meep: " + tr("recording") + " \(elapsed)"
        case .idle, .starting:
            toggleItem.title = tr("Start Recording")
            toggleItem.isEnabled = true
            button.toolTip = "Meep"
            if saving > 0 {
                icon = MenuBarIcons.saving
                label = percent
                healthItem.title = tr("Saving… %@", percent)
                healthItem.isHidden = false
                button.toolTip = "Meep: " + tr("saving") + " \(percent)"
            } else if recoveringPrevious {
                icon = MenuBarIcons.saving
                label = percent
                healthItem.title = tr("Finishing an unfinished recording… %@", percent)
                healthItem.isHidden = false
            }
        }
        if let p = progress, capture.session == nil, saving > 0 || recoveringPrevious {
            progressBar.doubleValue = p
            progressItem.isHidden = false
        }
        button.image = icon
        button.imagePosition = label.isEmpty ? .imageOnly : .imageLeading
        // Monospaced digits so the item does not jitter as the seconds tick.
        button.attributedTitle = NSAttributedString(string: label.isEmpty ? "" : " " + label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
        if icon == nil { button.title = capture.session != nil ? "🔴 " + label : (saving > 0 ? "⏳" : "🎙") }  // assets missing
    }

    /// Asks for microphone access the first time; afterwards returns the stored decision.
    private func micPermission() async -> Bool {
        switch Permissions.microphone {
        case .authorized: return true
        case .notDetermined:
            let granted = await Permissions.requestMicrophone()
            appState.refreshSources()  // Preferences shows the new status
            return granted
        default: return false
        }
    }

    /// First launch: both prompts, one after the other, so recording works without a trip to
    /// System Settings. Each is asked only while undecided.
    private func askForAccess() async {
        _ = await micPermission()
        if AppSettings.recordSystemAudio { await systemAudioPermission() }
    }

    /// Asks for system audio access while undecided. macOS would otherwise not ask: the tap just
    /// delivers silence.
    private func systemAudioPermission() async {
        guard Permissions.systemAudio == .notDetermined else { return }
        _ = await Permissions.requestSystemAudio()
        appState.refreshSources()
    }

    @objc private func openFolder() {
        RecordingSession.revealRootDirectory()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Quit, logout or shutdown: close the capture files and exit right away. Processing (AEC,
    /// mix, AAC) is not waited for; it runs on the next launch (see recoverUnfinishedSessions).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        capture.session?.stopCapture()
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

// Run through a symlink (e.g. Homebrew's `meep` in PATH), Bundle.main would be the
// symlink's folder: no Info.plist, translations or ffmpeg. Re-exec the real binary inside the .app.
if let exe = Bundle.main.executableURL?.standardizedFileURL,
   case let real = exe.resolvingSymlinksInPath(), real.path != exe.path {
    let argv = [real.path] + CommandLine.arguments.dropFirst()
    var cArgs = argv.map { strdup($0) } + [nil]
    execv(real.path, &cArgs)
    perror("execv \(real.path)")
    exit(1)
}

let cliArguments = Array(CommandLine.arguments.dropFirst())
if CLI.isInvocation(cliArguments) { CLI.main(cliArguments) }

// One instance: a copy started outside LaunchServices (e.g. the binary run directly, or another
// Meep.app with the same bundle id) hands over to the one already running, which shows Preferences.
if let id = Bundle.main.bundleIdentifier,
   let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
       .first(where: { $0.processIdentifier < getpid() }),
   let url = running.bundleURL {
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
        done.signal()
    }
    _ = done.wait(timeout: .now() + 5)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
