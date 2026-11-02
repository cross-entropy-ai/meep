import AppKit
import SwiftUI

/// Shared UI state for the preferences window.
/// (No @State in views: the SwiftUI macro plugin ships only with full Xcode, not the CLT.)
final class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var launchAtLogin = AppSettings.launchAtLogin
    @Published var loginError: String?
    @Published var justCopied: String?

    // Hotkey
    @Published var hotKey: Shortcut? = AppSettings.hotKey
    @Published var isCapturingHotKey = false
    @Published var hotKeyError: String?
    private var keyMonitor: Any?

    // Updates
    enum UpdateStatus: Equatable {
        case idle, checking, upToDate, available(version: String, url: URL), failed(String)
    }
    @Published var update: UpdateStatus = .idle

    /// Called when a setting that affects the menu bar changes.
    var onChange: () -> Void = {}

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.justCopied == id { self?.justCopied = nil }
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
                    self.hotKeyError = tr("Use at least one of ⌘, ⌥ or ⌃.", "至少要包含 ⌘、⌥ 或 ⌃。")
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
            hotKeyError = tr("\(s?.display ?? "") is already used by another app.", "\(s?.display ?? "") 已被其他 app 占用。")
            GlobalHotKey.shared.register(AppSettings.hotKey)  // keep the previous one
        }
    }

    // MARK: Update check (GitHub Releases)

    func checkForUpdate() {
        let repo = AppInfo.updateRepo
        guard !repo.isEmpty, let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            update = .failed(tr("No update source configured (MRUpdateGitHubRepo in Info.plist).", "未配置更新源（Info.plist 的 MRUpdateGitHubRepo）。"))
            return
        }
        update = .checking
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let result: UpdateStatus
            if let error {
                result = .failed(error.localizedDescription)
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String,
                      let page = (json["html_url"] as? String).flatMap(URL.init(string:)) {
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                result = latest.compare(AppInfo.version, options: .numeric) == .orderedDescending
                    ? .available(version: latest, url: page) : .upToDate
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                result = .failed(code == 404 ? tr("No releases found for \(repo).", "\(repo) 还没有发布版本。") : tr("Unexpected response (HTTP \(code)).", "响应异常（HTTP \(code)）。"))
            }
            DispatchQueue.main.async { self.update = result }
        }.resume()
    }
}

// MARK: - General

struct GeneralPreferencesView: View {
    @ObservedObject var state: AppState
    @AppStorage("language") private var language = AppLanguage.system.rawValue
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("showElapsedTime") private var showElapsed = true
    @AppStorage("echoCancellation") private var echoRaw = EchoMode.webrtc.rawValue
    @AppStorage("openFolderAfterSaving") private var openFolderAfterSaving = true

    var body: some View {
        Form {
            Section(tr("Launch", "启动")) {
                Toggle(tr("Start at Login", "开机启动"), isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }))
                if let e = state.loginError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
                LabeledContent(tr("Hotkey", "快捷键")) {
                    Button {
                        state.isCapturingHotKey ? state.endHotKeyCapture() : state.beginHotKeyCapture()
                    } label: {
                        Text(state.isCapturingHotKey ? tr("Press shortcut…", "请按下快捷键…")
                                                     : (state.hotKey?.display ?? tr("None", "无")))
                            .frame(minWidth: 110)
                    }
                    .help(tr("Start or stop recording from anywhere. Click, then press a new shortcut.",
                             "在任何地方开始或停止录制。点一下，再按下新的快捷键。"))
                }
                if let e = state.hotKeyError {
                    Text(e).font(.caption).foregroundStyle(.red)
                } else if state.isCapturingHotKey {
                    Text(tr("Esc to cancel · Delete to clear", "Esc 取消 · Delete 清除"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(tr("Appearance", "外观")) {
                Picker(tr("Language", "语言"), selection: $language) {
                    ForEach(AppLanguage.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Toggle(tr("Show Menu Bar Icon", "显示菜单栏图标"), isOn: $showMenuBarIcon)
                if !showMenuBarIcon {
                    Text(tr("The icon still appears while recording. Open the app again to show this window.",
                            "录制中仍会显示图标。再次打开 app 可回到这个窗口。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(tr("Show Recording Time", "显示录制时间"), isOn: $showElapsed)
            }

            Section(tr("Recording", "录制")) {
                Picker(selection: $echoRaw) {
                    ForEach(EchoMode.allCases, id: \.rawValue) { Text($0.shortTitle).tag($0.rawValue) }
                } label: {
                    Text(tr("Echo Cancellation", "回声消除"))
                    // Rendered as a subtitle, same as Recordings Folder.
                    if state.isRecording {
                        Text(tr("Can't change while recording.", "录制中不能切换。"))
                    } else if let detail = (EchoMode(rawValue: echoRaw) ?? .webrtc).detail {
                        Text(detail)
                    }
                }
                .disabled(state.isRecording)
                Toggle(tr("Open Folder After Saving", "保存后打开文件夹"), isOn: $openFolderAfterSaving)
                LabeledContent {
                    Button(tr("Show in Finder", "在 Finder 中显示")) {
                        let root = RecordingSession.rootDirectory
                        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(root)
                    }
                } label: {
                    Text(tr("Recordings Folder", "录音保存位置"))
                    Text(abbreviate(RecordingSession.rootDirectory.path))  // rendered as a subtitle
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize()
        .onAppear { state.launchAtLogin = AppSettings.launchAtLogin }
        .onDisappear { if state.isCapturingHotKey { state.endHotKeyCapture() } }
        .onChange(of: language) { _, _ in state.onChange() }
        .onChange(of: showMenuBarIcon) { _, _ in state.onChange() }
        .onChange(of: showElapsed) { _, _ in state.onChange() }
        .onChange(of: echoRaw) { _, _ in state.onChange() }
    }
}

// MARK: - Agent

/// Everything an AI agent or a script needs: how to drive the app and where results go.
struct AgentPreferencesView: View {
    @ObservedObject var state: AppState
    @AppStorage("language") private var language = AppLanguage.system.rawValue
    @AppStorage("afterSaveCommand") private var afterSaveCommand = ""

    static let urls = ["meetingrecorder://start", "meetingrecorder://stop", "meetingrecorder://preferences"]
    private var helpCommand: String { "\"\(Bundle.main.executableURL?.path ?? "MeetingRecorder")\" --help" }

    var body: some View {
        Form {
            Section {
                Text(tr("""
                    Agents and scripts can start and stop recording with the URLs below, check progress with \
                    --status, and read the results from the recordings folder: mixed.m4a, plus the separate \
                    tracks and session.json in raw/.
                    """, """
                    Agent 和脚本可以用下面的 URL 开始、停止录制，用 --status 查询进度，\
                    再从录音文件夹读取结果：mixed.m4a，以及 raw/ 里的分轨和 session.json。
                    """))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("URL Scheme") {
                ForEach(Self.urls, id: \.self) { url in
                    copyRow(url, copyText: "open \"\(url)\"")
                }
            }

            Section(tr("Command Line", "命令行")) {
                copyRow(helpCommand, copyText: helpCommand, wrap: true)
            }

            Section {
                TextField(tr("Run After Saving", "保存后运行"), text: $afterSaveCommand,
                          prompt: Text(verbatim: "~/bin/transcribe"))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text(tr("Run After Saving", "保存后运行"))
            } footer: {
                Text(tr("A shell command run after each recording is saved. It gets the recording folder as $1 and in $MEETINGRECORDER_DIR. Output goes to raw/after-save.log.",
                        "每次录音保存后执行的 shell 命令。录音文件夹作为 $1 传入，也在 $MEETINGRECORDER_DIR 里。输出写入 raw/after-save.log。"))
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
            .help(tr("Copy: ", "复制：") + copyText)
        }
    }
}

// MARK: - About

struct AboutPreferencesView: View {
    @ObservedObject var state: AppState
    @AppStorage("language") private var language = AppLanguage.system.rawValue

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.top, 24)
            Text(AppInfo.name)
                .font(.title2.weight(.semibold))
                .padding(.top, 10)
            Text(tr("Version", "版本") + " \(AppInfo.version) (\(AppInfo.build))")
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)

            HStack(spacing: 24) {
                link(tr("Privacy Policy", "隐私政策"), AppInfo.privacyPolicyURL)
                link(tr("Terms of Use", "使用条款"), AppInfo.termsOfUseURL)
            }
            .padding(.top, 18)

            Text(AppInfo.copyright)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 10)

            Button(action: state.checkForUpdate) {
                Text(state.update == .checking ? tr("Checking…", "正在检查…") : tr("Check for Updates", "检查更新"))
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
        case .upToDate: Text(tr("You're up to date.", "已是最新版本。")).foregroundStyle(.secondary)
        case .available(let v, let url):
            HStack(spacing: 4) {
                Text(tr("Version \(v) is available.", "有新版本 \(v)。")).foregroundStyle(.secondary)
                Link(tr("Download", "下载"), destination: url)
            }
        case .failed(let msg): Text(msg).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func link(_ title: String, _ url: URL?) -> some View {
        if let url {
            Link(title, destination: url)
        } else {
            Text(title).foregroundStyle(.tertiary).help(tr("Not configured yet", "尚未配置"))
        }
    }
}

private func abbreviate(_ path: String) -> String {
    path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

// MARK: - Window

/// A single reusable preferences window with toolbar tabs (General / Agent / About).
final class PreferencesWindowController: NSWindowController {
    enum Tab: Int, CaseIterable {
        case general, agent, about

        var label: String {
            switch self {
            case .general: return tr("General", "通用")
            case .agent: return "Agent"
            case .about: return tr("About", "关于")
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
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
        tabs.addTabViewItem(host(AgentPreferencesView(state: state), .agent))
        tabs.addTabViewItem(host(AboutPreferencesView(state: state), .about))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        self.init(window: window)
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
        if window?.isVisible == false { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        // Select after the window (and the tab view) has loaded; selecting earlier gets reset.
        if let tab, let tabs = contentViewController as? NSTabViewController {
            tabs.selectedTabViewItemIndex = tab.rawValue
        }
    }
}

extension EchoMode {
    var shortTitle: String {
        switch self {
        case .off: return tr("Off", "关闭")
        case .apple: return tr("Apple Voice Processing", "Apple 语音处理")
        case .webrtc: return "WebRTC AEC3"
        }
    }

    /// Subtitle under the picker; nil = none.
    var detail: String? {
        switch self {
        case .off: return nil
        case .apple: return tr("Real-time, but lowers other apps' volume.", "实时处理，但会压低其他 app 的音量。")
        case .webrtc: return tr("Processed after stopping, better quality.", "停止后处理，效果更好。")
        }
    }
}
