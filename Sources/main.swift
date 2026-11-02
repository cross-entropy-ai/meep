import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var healthItem: NSMenuItem!
    private var folderItem: NSMenuItem!
    private var prefsItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var session: RecordingSession?
    private var timer: Timer?
    private var stopping = false
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
        folderItem = NSMenuItem(title: "", action: #selector(openFolder), keyEquivalent: "o")
        menu.addItem(folderItem)
        menu.addItem(.separator())
        prefsItem = NSMenuItem(title: "", action: #selector(showPreferences), keyEquivalent: ",")
        menu.addItem(prefsItem)
        menu.addItem(.separator())
        quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
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
            requestMicPermissionIfNeeded { _ in }
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

    /// Finishes recordings left behind by a crash or force quit (raw PCM → final outputs).
    private func recoverUnfinishedSessions() {
        DispatchQueue.global(qos: .utility).async {
            let dirs = Finalizer.recoverUnfinished(root: RecordingSession.rootDirectory)
            guard !dirs.isEmpty else { return }
            dirs.forEach(AfterSaveHook.run)
            DispatchQueue.main.async {
                self.alert(tr("Recovered unfinished recordings", "已恢复未完成的录音"),
                           tr("The app quit unexpectedly during recording. These recordings were recovered from the capture files:",
                              "上次录制时程序意外退出，以下录音已从临时文件恢复并处理完成：") + "\n\n"
                           + dirs.map(\.lastPathComponent).joined(separator: "\n"))
            }
        }
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
        case "preferences/agent": preferences.show(tab: .agent)
        case "preferences/about": preferences.show(tab: .about)
        default: break
        }
    }

    @objc private func toggle() {
        if stopping { return }
        if let s = session { stop(s) } else { start() }
    }

    private func start() {
        requestMicPermissionIfNeeded { [self] granted in
            if !granted {
                self.alert(tr("No microphone access", "没有麦克风权限"),
                           tr("Allow MeetingRecorder in System Settings › Privacy & Security › Microphone. This recording captures system audio only.",
                              "请到 系统设置 › 隐私与安全性 › 麦克风 中允许 MeetingRecorder。本次只录系统声音。"),
                           settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            }
            do {
                let s = try RecordingSession()
                try s.start()
                self.session = s
                self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateUI() }
            } catch {
                self.alert(tr("Can't start recording", "无法开始录制"), "\(error)")
            }
            self.updateUI()
        }
    }

    private func stop(_ s: RecordingSession) {
        stopping = true
        timer?.invalidate(); timer = nil
        updateUI()
        DispatchQueue.global(qos: .userInitiated).async {
            let warnings = s.stop()
            AfterSaveHook.run(s.directory)
            DispatchQueue.main.async {
                self.session = nil
                self.stopping = false
                self.updateUI()
                if !warnings.isEmpty {
                    self.alert(tr("Recording saved with warnings", "录制已保存，但有提示"), warnings.joined(separator: "\n\n"),
                               settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
                }
                if AppSettings.openFolderAfterSaving {
                    // Select the mix (what most people want); fall back to the folder.
                    let mixed = s.directory.appendingPathComponent("mixed.m4a")
                    let target = FileManager.default.fileExists(atPath: mixed.path) ? mixed : s.directory
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                }
            }
        }
    }

    private func updateUI() {
        guard let button = statusItem?.button else { return }
        let recording = session != nil || stopping
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
        folderItem.title = tr("Open Recordings Folder", "打开录音文件夹")
        prefsItem.title = tr("Open Preferences…", "打开偏好设置…")
        quitItem.title = tr("Quit", "退出")
        var icon = MenuBarIcons.idle
        var label = ""
        if stopping {
            icon = MenuBarIcons.saving
            toggleItem.title = tr("Saving…", "正在保存…")
            toggleItem.isEnabled = false
            button.toolTip = "MeetingRecorder: " + tr("saving", "正在保存")
        } else if let s = session {
            let elapsed = RecordingSession.clock(Date().timeIntervalSince(s.startedAt))
            toggleItem.title = tr("Stop Recording (\(elapsed))", "停止录制（\(elapsed)）")
            toggleItem.isEnabled = true
            icon = MenuBarIcons.recording
            if AppSettings.showElapsedTime { label = elapsed }
            switch s.health {
            case .ok:
                break
            case .recovering(let t):
                icon = MenuBarIcons.recovering
                healthItem.title = t == .mic ? tr("Recovering microphone…", "正在恢复麦克风…")
                                             : tr("Recovering system audio…", "正在恢复系统声音…")
                healthItem.isHidden = false
            case .lost(let t):
                icon = MenuBarIcons.recovering
                healthItem.title = "⚠️ " + (t == .mic ? tr("Microphone lost, retrying", "麦克风已断开，持续重试中")
                                                     : tr("System audio lost, retrying", "系统声音已断开，持续重试中"))
                healthItem.isHidden = false
            }
            button.toolTip = "MeetingRecorder: " + tr("recording", "录制中") + " \(elapsed)"
        } else {
            toggleItem.title = tr("Start Recording", "开始录制")
            toggleItem.isEnabled = true
            button.toolTip = "MeetingRecorder"
        }
        button.image = icon
        button.imagePosition = label.isEmpty ? .imageOnly : .imageLeading
        // Monospaced digits so the item does not jitter as the seconds tick.
        button.attributedTitle = NSAttributedString(string: label.isEmpty ? "" : " " + label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
        if icon == nil { button.title = stopping ? "⏳" : (session != nil ? "🔴 " + label : "🎙") }  // assets missing
    }

    private func requestMicPermissionIfNeeded(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    @objc private func openFolder() {
        let root = RecordingSession.rootDirectory
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    @objc private func quit() {
        if let s = session { _ = s.stop() }
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ text: String, settingsURL: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: tr("OK", "好"))
        if settingsURL != nil { a.addButton(withTitle: tr("Open System Settings", "打开系统设置")) }
        if a.runModal() == .alertSecondButtonReturn, let u = settingsURL, let url = URL(string: u) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - CLI (see HelpText in Agent.swift)

func runCLI(_ body: () throws -> Void) -> Never {
    do { try body(); exit(0) } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let cli = CommandLine.arguments
if cli.count >= 2 && ["--help", "-h", "help"].contains(cli[1]) {
    print(HelpText.text)
    exit(0)
}
if cli.count >= 2 && cli[1] == "--status" {
    print(StatusReport.json())
    exit(0)
}
if cli.count >= 3 && cli[1] == "--login-item" {
    runCLI {
        if cli[2] != "status" { try AppSettings.setLaunchAtLogin(cli[2] == "on") }
        print("launch at login: \(AppSettings.launchAtLogin ? "on" : "off")")
    }
}
if cli.count >= 3 && cli[1] == "--remix" {
    runCLI {
        let dir = URL(fileURLWithPath: cli[2], isDirectory: true)
        let raw = Finalizer.rawDir(dir)
        let aec = raw.appendingPathComponent("mic_aec.caf")
        let mic = FileManager.default.fileExists(atPath: aec.path) ? aec : raw.appendingPathComponent("mic.caf")
        let r = try Mixer.mix(system: raw.appendingPathComponent("system.caf"), mic: mic,
                              output: dir.appendingPathComponent("mixed.m4a"))
        print("wrote \(dir.appendingPathComponent("mixed.m4a").path)  loudness LUFS: \(r.loudnessLUFS)  gain dB: \(r.gainsDB)")
    }
}
if cli.count >= 3 && cli[1] == "--aec" {
    runCLI {
        let dir = URL(fileURLWithPath: cli[2], isDirectory: true)
        let raw = Finalizer.rawDir(dir)
        let out = cli.count >= 4 ? URL(fileURLWithPath: cli[3]) : raw.appendingPathComponent("mic_aec.caf")
        try EchoCanceller.process(system: raw.appendingPathComponent("system.caf"),
                                  mic: raw.appendingPathComponent("mic.caf"), output: out)
        print("wrote \(out.path)")
    }
}
if cli.count >= 2 && cli[1].hasPrefix("--") {
    FileHandle.standardError.write("unknown or incomplete option: \(cli.dropFirst().joined(separator: " "))\nsee --help\n".data(using: .utf8)!)
    exit(2)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
