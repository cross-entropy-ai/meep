import Foundation
import Synchronization

/// Command-line interface (usage: HelpText at the end of this file).
/// stdout carries only results (a path, a word, or JSON); diagnostics and progress go to stderr.
/// Exit codes: 0 ok, 1 failed, 2 usage error, 3 timed out.
enum CLI {
    enum Exit: Int32 { case ok = 0, failed = 1, usage = 2, timeout = 3 }

    /// Bad command line: reported with exit code 2.
    struct UsageError: Error { let message: String }

    /// A runtime failure with a plain message: exit code 1.
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Whether `args` (without the program name) is a CLI invocation. No arguments, or the
    /// arguments macOS and Cocoa add at launch (-psn_0_1234, -NSDocumentRevisionsDebugMode YES,
    /// -AppleLanguages …), mean: launch the GUI. Anything else is the CLI, which reports what it
    /// doesn't know instead of silently opening the app.
    /// Exception: no arguments typed in a terminal (stdin is a tty; LaunchServices gives the app
    /// /dev/null) is the CLI too, which opens the app the way the Dock does (`openApp`).
    static func isInvocation(_ args: [String]) -> Bool {
        guard let first = args.first else { return isatty(STDIN_FILENO) != 0 }
        return !["-psn_", "-NS", "-Apple"].contains { first.hasPrefix($0) }
    }

    /// Runs the command in `args` (non-empty) and exits.
    static func main(_ args: [String]) -> Never {
        if args.isEmpty { exit(openApp()) }
        let rest = Array(args.dropFirst())
        do {
            let code: Exit
            switch args[0] {
            case "help", "-h", "--help": code = try help(rest)
            case "version": code = try version(rest)
            case "status": code = try status(rest)
            case "login-item": code = try loginItem(rest)
            case "aec": code = try aec(rest)
            case "remix": code = try remix(rest)
            case "mix": code = try mix(rest)
            case "start": code = try start(rest)
            case "stop": code = try stop(rest)
            default: throw UsageError(message: "unknown command: \(args[0])")
            }
            exit(code.rawValue)
        } catch let e as UsageError {
            printErr("error: \(e.message)\nusage: meep help")
            exit(Exit.usage.rawValue)
        } catch {
            printErr("error: \(error)")
            exit(Exit.failed.rawValue)
        }
    }

    // MARK: - Commands

    static func help(_ args: [String]) throws -> Exit {
        _ = try Args(args)
        print(HelpText.text)
        return .ok
    }

    /// `version`: the app version, e.g. "0.5.1".
    static func version(_ args: [String]) throws -> Exit {
        _ = try Args(args)
        print(AppInfo.version)
        return .ok
    }

    /// `status [--json]`: the state (idle, recording or saving); --json: the full report.
    static func status(_ args: [String]) throws -> Exit {
        let a = try Args(args, flags: ["--json"])
        let report = StatusReport.report()
        if a.has("--json") { JSON.print(report) } else { print(report.state.rawValue) }
        return .ok
    }

    static func loginItem(_ args: [String]) throws -> Exit {
        let a = try Args(args, count: 1...1)
        let value = a.positional[0]
        guard ["on", "off", "status"].contains(value) else {
            throw UsageError(message: "login-item takes on, off or status, not \(value)")
        }
        if value != "status" { try AppSettings.setLaunchAtLogin(value == "on") }
        print(AppSettings.launchAtLogin ? "on" : "off")  // e.g. [ "$(… login-item status)" = on ]
        return .ok
    }

    /// `start [--wait] [--timeout <sec>]`: asks the app to start recording. With --wait, returns
    /// once a recording is live and prints its folder; exit 1 if the app could not start it
    /// (reason on stderr), 3 on timeout. Already recording: that recording counts (exit 0).
    static func start(_ args: [String]) throws -> Exit {
        let (wait, timeout) = try waitOptions(args, defaultTimeout: 15)
        if let c = StatusReport.current, c.state == .recording {
            printErr("already recording")
            if wait { print(c.dir) }
            return .ok
        }
        let sent = Date()
        try send("start")
        guard wait else { return .ok }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let c = StatusReport.current, c.state == .recording {
                print(c.dir)
                return .ok
            }
            if let error = StartFailure.since(sent) {
                printErr("could not start recording: \(error)")
                return .failed
            }
            if Date() >= deadline {
                printErr("timed out after \(String(format: "%g", timeout)) s: no recording started")
                return .timeout
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// `stop [--wait] [--timeout <sec>]`: asks the app to stop recording. With --wait, returns once
    /// the recording is saved and prints its folder: exit 0 if its status is "complete" or
    /// "recovered" (interrupted, every track restored), 1 for any other status, 3 on timeout.
    /// Not recording: nothing to do, exit 0 ("not recording" on stderr).
    static func stop(_ args: [String]) throws -> Exit {
        let (wait, timeout) = try waitOptions(args, defaultTimeout: 600)
        // The recording this stop is about (not one that is only being saved already).
        let live = StatusReport.current.flatMap { $0.state == .recording ? URL(fileURLWithPath: $0.dir) : nil }
        try send("stop")  // also when idle: a start may be on its way in the app
        guard let dir = live else {
            printErr("not recording")
            return .ok
        }
        guard wait else { return .ok }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let status = Session.read(dir)?.status
            if let status, !status.isUnfinished {
                print(dir.path)
                if status.isOK { return .ok }
                printErr("recording saved with status \(status.rawValue) (see \(Finalizer.rawFolder)/session.json)")
                return .failed
            }
            if Date() >= deadline {
                printErr("timed out after \(String(format: "%g", timeout)) s: \(dir.path) is not saved yet"
                         + " (status \(status?.rawValue ?? "unknown"))")
                return .timeout
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// `--wait` and `--timeout <sec>` (positive number).
    private static func waitOptions(_ args: [String], defaultTimeout: Double) throws(UsageError) -> (Bool, Double) {
        let a = try Args(args, options: ["--timeout"], flags: ["--wait"])
        var timeout = defaultTimeout
        if let t = a["--timeout"] {
            guard let v = Double(t), v > 0 else { throw UsageError(message: "--timeout needs a positive number of seconds, not \(t)") }
            timeout = v
        }
        return (a.has("--wait"), timeout)
    }

    /// `meep` alone: opens this Meep.app through LaunchServices, which shows the running
    /// instance's Preferences instead of starting a second one, and returns at once.
    static func openApp() -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [Bundle.main.bundlePath]
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { printErr("error: \(error.localizedDescription)"); return Exit.failed.rawValue }
        p.waitUntilExit()
        return p.terminationStatus == 0 ? Exit.ok.rawValue : Exit.failed.rawValue
    }

    /// Sends meep://<command>?quiet through LaunchServices (`open -g`), which launches
    /// the app in the background if it is not running. `quiet`: no alerts or Finder window for
    /// recordings a script starts or stops.
    static func send(_ command: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "meep://\(command)?quiet"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.standardError  // keep stdout for results
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Failure("could not open meep://\(command) (is Meep installed?)")
        }
    }

    /// `aec --system <file> --mic <file> -o <out.caf|.wav>`: removes the system audio's echo from
    /// the mic track (plus low noise suppression).
    static func aec(_ args: [String]) throws -> Exit {
        let a = try Args(args, options: ["--system", "--mic", "-o"])
        guard let system = a["--system"], let mic = a["--mic"], let out = a["-o"] else {
            throw UsageError(message: "aec needs --system <file> --mic <file> -o <out>")
        }
        let output = URL(fileURLWithPath: out)
        try checkExtension(output, MicProcessor.outputExtensions)
        try runAEC(system: try inputFile(system), mic: try inputFile(mic), output: output)
        print(output.path)
        return .ok
    }

    /// `remix <recording-dir> [--redo-mic] [--json] [-v]`: re-mixes a recording into mixed.m4a.
    /// --redo-mic first redoes the mic processing with the settings it was recorded with and
    /// replaces raw/mic_aec.caf. Updates session.json.
    static func remix(_ args: [String]) throws -> Exit {
        let a = try Args(args, flags: ["--redo-mic", "--json", "-v"], count: 1...1)
        let dir = try recordingDir(a.positional[0])
        let (lock, session) = try own(dir)
        defer { lock.release() }
        var meta = session
        let raw = Finalizer.rawDir(dir)
        // Prefer lossless files (present if encoding failed or has not run yet), and the AEC mic.
        let system = try? firstExisting(raw, [Finalizer.systemPCM, "system.caf"])
        let mic = try? firstExisting(raw, [Finalizer.micAECPCM, "mic_aec.caf", Finalizer.micPCM, "mic.caf"])

        if a.has("--redo-mic") {
            let rawMic = try firstExisting(raw, [Finalizer.micPCM, "mic.caf"])
            let options = meta.micOptions(hasSystem: system != nil, hasMic: true)
            if options.summary.isEmpty {
                printErr(meta.echoCancellation == .apple
                    ? "--redo-mic: Apple voice processing already processed this recording's microphone"
                    : "--redo-mic: echo cancellation, noise suppression and auto level are off for this recording")
            } else {
                // Lossless result, encoded to mic_aec.caf and mixed from; it goes either way.
                let pcm = raw.appendingPathComponent(Finalizer.micAECPCM)
                defer { try? FileManager.default.removeItem(at: pcm) }
                try runAEC(system: system, mic: rawMic, output: pcm, options: options)
                let out = raw.appendingPathComponent("mic_aec.caf")
                try Finalizer.writeAtomically(to: out) { temp in
                    try Finalizer.encodeAAC(pcm, to: temp, bitRate: 64_000, progress: progress("encode"))
                }
                progressDone()
                meta.micProcessing = options.summary
                meta.tracks.micAec = Session.Track(file: "\(Finalizer.rawFolder)/mic_aec.caf",
                                                   durationSec: Finalizer.duration(out),
                                                   format: "AAC 48kHz mono 64kbps, WebRTC " + options.summary)
                if !meta.write(to: dir) { printErr("warning: could not update session.json") }
                return try runMix(system: system, mic: pcm, output: dir.appendingPathComponent("mixed.m4a"),
                                  json: a.has("--json"), verbose: a.has("-v")) { r in
                    meta.setMix(r)
                    if !meta.write(to: dir) { printErr("warning: could not update session.json") }
                }
            }
        }
        guard system != nil || mic != nil else { throw Failure("no tracks found in \(raw.path)") }
        return try runMix(system: system, mic: mic, output: dir.appendingPathComponent("mixed.m4a"),
                          json: a.has("--json"), verbose: a.has("-v")) { r in
            meta.setMix(r)
            if !meta.write(to: dir) { printErr("warning: could not update session.json") }
        }
    }

    /// Takes a recording folder for this command: one the app is no longer recording, saving or
    /// due to finish. Held until the command ends, so the app can't start processing it meanwhile.
    private static func own(_ dir: URL) throws -> (SessionLock, Session) {
        guard Session.read(dir) != nil else {
            throw Failure("not a Meep recording (no readable \(Finalizer.rawFolder)/session.json): \(dir.path)")
        }
        guard let lock = SessionLock(dir) else {
            throw Failure("\(dir.path) is in use (being recorded, saved, or remixed)")
        }
        guard let s = Session.read(dir) else { throw Failure("can't read \(Session.url(dir).path)") }
        guard !s.status.isUnfinished else {
            throw Failure("\(dir.path) is unfinished (status \(s.status.rawValue)); open Meep to finish it first")
        }
        return (lock, s)
    }

    /// `mix [--system <file>] [--mic <file>] -o <out.m4a|.wav|.caf> [--json] [-v]`: loudness-matched mix.
    static func mix(_ args: [String]) throws -> Exit {
        let a = try Args(args, options: ["--system", "--mic", "-o"], flags: ["--json", "-v"])
        guard let out = a["-o"] else { throw UsageError(message: "mix needs -o <out>") }
        guard a["--system"] != nil || a["--mic"] != nil else {
            throw UsageError(message: "mix needs --system <file>, --mic <file>, or both")
        }
        let output = URL(fileURLWithPath: out)
        try checkExtension(output, Mixer.outputExtensions)
        return try runMix(system: try a["--system"].map(inputFile), mic: try a["--mic"].map(inputFile),
                          output: output, json: a.has("--json"), verbose: a.has("-v"))
    }

    // MARK: - Shared steps

    static func runAEC(system: URL?, mic: URL, output: URL,
                       options: MicProcessor.Options = MicProcessor.Options()) throws {
        try checkNotInput(output, [system, mic])
        defer { progressDone() }
        try MicProcessor.process(system: system, mic: mic, output: output, options: options, progress: progress("aec"))
    }

    /// `mix --json` output.
    private struct MixReport: Encodable {
        var output: String
        var loudnessLufs: [String: Double]
        var gainDb: [String: Double]
    }

    /// Mixes, then prints the output path (or with `json`, a JSON object) on stdout; with
    /// `verbose`, the loudness/gain summary on stderr. `done` runs after a successful mix.
    static func runMix(system: URL?, mic: URL?, output: URL, json: Bool, verbose: Bool,
                       done: (Mixer.Result) -> Void = { _ in }) throws -> Exit {
        try checkNotInput(output, [system, mic])
        let r: Mixer.Result
        do {
            defer { progressDone() }
            r = try Mixer.mix(system: system, mic: mic, output: output, progress: progress("mix"))
        }
        done(r)
        if json {
            JSON.print(MixReport(output: output.path, loudnessLufs: r.loudnessLUFS, gainDb: r.gainsDB))
        } else {
            print(output.path)
            for name in ["system", "mic"] where verbose {
                guard let gain = r.gainsDB[name] else { continue }
                let lufs = r.loudnessLUFS[name].map { String(format: "%.1f LUFS", $0) } ?? "not measured"
                printErr("\(name): loudness \(lufs), gain \(String(format: "%+.1f", gain)) dB")
            }
        }
        return .ok
    }

    static func recordingDir(_ path: String) throws -> URL {
        var isDir: ObjCBool = false
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure("not a directory: \(path)")
        }
        return dir
    }

    static func inputFile(_ path: String) throws -> URL {
        guard FileManager.default.fileExists(atPath: path) else { throw Failure("no such file: \(path)") }
        return URL(fileURLWithPath: path)
    }

    static func firstExisting(_ dir: URL, _ names: [String]) throws -> URL {
        guard let u = names.map({ dir.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw Failure("none of \(names.joined(separator: ", ")) in \(dir.path)")
        }
        return u
    }

    /// Writing the output over an input would destroy it before it is read. Compared by file
    /// identity, so case-insensitive spellings, symlinks and hard links are caught too.
    static func checkNotInput(_ output: URL, _ inputs: [URL?]) throws(UsageError) {
        func id(_ u: URL) -> NSObject? {
            (try? u.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
        }
        guard let out = id(output) else { return }  // output doesn't exist yet
        if inputs.compactMap({ $0 }).contains(where: { id($0).map { $0.isEqual(out) } ?? false }) {
            throw UsageError(message: "output is also an input: \(output.path)")
        }
    }

    static func checkExtension(_ url: URL, _ allowed: Set<String>) throws(UsageError) {
        guard allowed.contains(url.pathExtension.lowercased()) else {
            throw UsageError(message: "output must end in " + allowed.sorted().map { "." + $0 }.joined(separator: ", ")
                             + ": \(url.lastPathComponent)")
        }
    }

    // MARK: - Output

    static func printErr(_ s: String, newline: Bool = true) {
        FileHandle.standardError.write(Data((newline ? s + "\n" : s).utf8))
    }

    /// The progress line currently on stderr (nil = none). Progress can come from any thread.
    private static let progressLine = Mutex<String?>(nil)

    /// "label 42%" on stderr, redrawn in place; only when stderr is a terminal.
    static func progress(_ label: String) -> @Sendable (Double) -> Void {
        guard isatty(STDERR_FILENO) != 0 else { return { _ in } }
        return { f in
            let line = "\(label) \(Int(min(max(f, 0), 1) * 100))%"
            CLI.progressLine.withLock { shown in
                guard shown != line else { return }
                shown = line
                CLI.printErr("\r\u{1B}[K" + line, newline: false)
            }
        }
    }

    /// Clears the progress line.
    static func progressDone() {
        progressLine.withLock { shown in
            if shown != nil { CLI.printErr("\r\u{1B}[K", newline: false) }
            shown = nil
        }
    }
}

/// One command's arguments: options with a value (`--name value`, `--name=value`), flags, and
/// positionals. "--" ends the options. Anything unexpected throws CLI.UsageError.
struct Args {
    private(set) var values: [String: String] = [:]
    private(set) var flags: Set<String> = []
    private(set) var positional: [String] = []

    init(_ args: [String], options: Set<String> = [], flags flagNames: Set<String> = [],
         count: ClosedRange<Int> = 0...0) throws(CLI.UsageError) {
        func usage(_ m: String) -> CLI.UsageError { CLI.UsageError(message: m) }
        var i = 0
        var optionsEnded = false
        while i < args.count {
            let arg = args[i]
            i += 1
            if optionsEnded || arg == "-" || !arg.hasPrefix("-") { positional.append(arg); continue }
            if arg == "--" { optionsEnded = true; continue }
            var name = arg
            var inline: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                name = String(arg[..<eq])
                inline = String(arg[arg.index(after: eq)...])
            }
            if flagNames.contains(name) {
                guard inline == nil else { throw usage("\(name) takes no value") }
                guard flags.insert(name).inserted else { throw usage("\(name) given twice") }
            } else if options.contains(name) {
                var value = inline
                if value == nil, i < args.count, args[i] == "-" || !args[i].hasPrefix("-") {
                    value = args[i]
                    i += 1
                }
                guard let v = value, !v.isEmpty else { throw usage("\(name) needs a value") }
                guard values[name] == nil else { throw usage("\(name) given twice") }
                values[name] = v
            } else {
                throw usage("unknown option: \(arg)")
            }
        }
        if positional.count > count.upperBound {
            throw usage("unexpected argument: \(positional[count.upperBound])")
        }
        if positional.count < count.lowerBound {
            throw usage("missing argument")
        }
    }

    subscript(_ option: String) -> String? { values[option] }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
}

enum HelpText {
    static var text: String {
        let exe = "meep"
        return """
        Meep — records system audio + microphone for meetings.
        CLI: \(Bundle.main.executableURL?.path ?? exe) <command>

        CONTROL (the app must be installed; these launch it if needed)
          \(exe) start [--wait] [--timeout <sec>]
              Start recording. --wait: return once it is live and print its folder (timeout 15 s);
              exit 1 with the reason if the app could not start. Already recording: exit 0.
          \(exe) stop [--wait] [--timeout <sec>]
              Stop recording. --wait: return once it is saved and print its folder (timeout 600 s);
              exit 0 if its status is "complete" or "recovered", 1 otherwise. Not recording: exit 0
              with nothing on stdout (a start still in flight is stopped, but not waited for).
              Recordings started or stopped here show no alerts and open no Finder window.
          \(exe) status [--json]
              Prints idle, recording or saving. --json: {"state", "current": {...} | null,
                "latest": {"dir", "mixed", "status", "after_save", ...} | null, "recordings_folder"}
              status of a recording: recording | saving | complete | recovered | incomplete
                (a track was lost or recorded nothing) | recovered_after_crash
          URL scheme: open "meep://start" (also stop, preferences); returns at once.
              Add ?quiet (meep://start?quiet) for no alerts or Finder window.

        PROCESSING (inputs: .caf .wav .m4a .aac .mp3 .flac .ogg; output format follows the extension)
          \(exe) aec --system <file> --mic <file> -o <out.caf|.wav>
              WebRTC echo cancellation (removes the system audio from the mic), plus low noise
              suppression and a high-pass filter; ignores Preferences. 16-bit PCM.
          \(exe) mix [--system <file>] [--mic <file>] -o <out.m4a|.wav|.caf> [--json] [-v]
              Loudness-matched mix: AAC (.m4a) or 16-bit PCM (.wav/.caf).
              --json: output, loudness and gains as JSON on stdout; -v: loudness and gains on stderr.
          \(exe) remix <recording-dir> [--redo-mic] [--json] [-v]
              Re-mix a recording into mixed.m4a and update session.json. --redo-mic: first redo
              the mic processing with the settings it was recorded with (echo cancellation, noise
              suppression, auto level), replacing raw/mic_aec.caf.
          Outputs are written to a temporary file first and replace the target only on success.
          remix refuses a recording that is still being recorded, saved, or unfinished.

        OTHER
          \(exe) login-item on|off|status      Start at Login; prints on or off
          \(exe) version                       e.g. \(AppInfo.version)
          \(exe) help

        CONVENTIONS
          stdout carries only results (a path, a word, or JSON); messages and progress go to stderr.
          Exit codes: 0 ok, 1 failed, 2 bad usage, 3 timed out.

        OUTPUT  \(RecordingSession.rootDirectory.path)/<yyyy-MM-dd_HHmmss>/
          mixed.m4a          system audio + microphone, loudness-matched
          raw/system.caf     what the Mac played (other participants)
          raw/mic.caf        microphone (you)
          raw/mic_aec.caf    microphone after WebRTC post-processing: echo cancellation,
                             noise suppression, auto level (what ran: mic_processing in session.json)
          raw/session.json   status, timing, interruptions, warnings
          raw/after-save.json  state of the Run After Saving command
          All tracks start at the same moment: sample N of every file is the same instant.
          Folder: Preferences › General › Recordings Folder, i.e.
            defaults write dev.junyi.Meep recordingsFolder -string <path>

        AFTER SAVING
          Preferences › Agent › Run After Saving: a shell command run after each recording is saved.
          Meep adds the recording folder to the end of the command (it is also $1 and $MEEP_DIR),
          so don't name it again. Output: raw/after-save.log.
          Recipes (transcribe, summarize with an agent): https://github.com/cross-entropy-ai/meep/blob/main/docs/recipes.md
          raw/after-save.json: {"status": "running|done|failed", "exit_status", ...}.
          Runs via zsh -lc: ~/.zprofile is read, ~/.zshrc is not (set PATH there or use full paths).

        SETTINGS (defaults write dev.junyi.Meep <key> <value>; Preferences sets the same)
          inputDeviceUID -string <uid>|""     microphone; "" = system default
          recordSystemAudio -bool true|false   record what the Mac plays
          echoCancellation -string webrtc|apple|off
          noiseSuppression -string off|low|moderate|high|very_high
          autoLevel -bool true|false
          recordingsFolder -string <path>
          afterSaveCommand -string <command>
          openFolderAfterSaving -bool true|false
          SUEnableAutomaticChecks -bool true|false, SUScheduledCheckInterval -int <seconds>
                                               automatic update check (Sparkle)
        """
    }
}
