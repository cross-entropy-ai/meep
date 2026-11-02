import Foundation
import Synchronization

/// Command-line interface (usage: HelpText in Agent.swift).
/// stdout carries only results (a path, or JSON); diagnostics and progress go to stderr.
/// Exit codes: 0 ok, 1 failed, 2 usage error, 3 timed out.
enum CLI {
    enum Exit: Int32 { case ok = 0, failed = 1, usage = 2, timeout = 3 }

    /// Bad command line: reported with exit code 2.
    struct UsageError: Error { let message: String }

    /// A runtime failure with a plain message: exit code 1.
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Whether `args` (without the program name) is a CLI invocation. No arguments, or the
    /// arguments macOS and Cocoa add at launch (-psn_0_1234, -NSDocumentRevisionsDebugMode YES,
    /// -AppleLanguages …), mean: launch the GUI. Anything else (also `-help`) is the CLI, which
    /// reports what it doesn't know instead of silently opening the app.
    static func isInvocation(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        return !["-psn_", "-NS", "-Apple"].contains { first.hasPrefix($0) }
    }

    /// Runs the command in `args` (non-empty) and exits. `cmd` and `--cmd` are the same command.
    static func main(_ args: [String]) -> Never {
        let name = if args[0] == "-h" { "help" } else if args[0].hasPrefix("--") { String(args[0].dropFirst(2)) } else { args[0] }
        let rest = Array(args.dropFirst())
        do {
            let code: Exit
            switch name {
            case "help": code = try help(rest)
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
            printErr("error: \(e.message)\nusage: Meep help")
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

    /// `status [--json]`: always JSON (--json is accepted for symmetry with other commands).
    static func status(_ args: [String]) throws -> Exit {
        _ = try Args(args, flags: ["--json"])
        printJSON(StatusReport.report())
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
        try checkSameFolderAsApp()
        if let c = StatusReport.current, c.state == "recording" {
            printErr("already recording")
            if wait { print(c.dir.path) }
            return .ok
        }
        let sent = Date()
        try send("start")
        guard wait else { return .ok }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let c = StatusReport.current, c.state == "recording" {
                print(c.dir.path)
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
        try checkSameFolderAsApp()
        // The recording this stop is about (not one that is only being saved already).
        let live = StatusReport.current.flatMap { $0.state == "recording" ? $0.dir : nil }
        try send("stop")  // also when idle: a start may be on its way in the app
        guard let dir = live else {
            printErr("not recording")
            return .ok
        }
        guard wait else { return .ok }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let status = Finalizer.readMeta(dir)?["status"] as? String ?? ""
            if !["", "recording", "saving"].contains(status) {
                print(dir.path)
                if ["complete", "recovered"].contains(status) { return .ok }
                printErr("recording saved with status \(status) (see \(Finalizer.rawFolder)/session.json)")
                return .failed
            }
            if Date() >= deadline {
                printErr("timed out after \(String(format: "%g", timeout)) s: \(dir.path) is not saved yet (status \(status))")
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

    /// The app reads the recordings folder from its settings; $MEEP_ROOT only reaches
    /// this process. If they differ, --wait and status would watch the wrong folder forever.
    private static func checkSameFolderAsApp() throws(UsageError) {
        guard AppSettings.recordingsFolderFromEnvironment else { return }
        let app = AppSettings.appRecordingsFolder.resolvingSymlinksInPath().path
        let mine = AppSettings.recordingsFolder.resolvingSymlinksInPath().path
        guard mine == app else {
            throw UsageError(message: "MEEP_ROOT (\(mine)) differs from the app's recordings folder (\(app)); "
                             + "unset it, or set the folder with defaults write com.junyi.Meep recordingsFolder")
        }
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
            throw Failure(description: "could not open meep://\(command) (is Meep installed?)")
        }
    }

    /// `aec --system <file> --mic <file> -o <out.caf|.wav>`: removes the system audio's echo from
    /// the mic track (plus low noise suppression). Or `aec <recording-dir> [out]`: redoes a
    /// recording's mic processing with the settings it was recorded with (session.json); without
    /// [out] it replaces raw/mic_aec.caf and updates session.json.
    static func aec(_ args: [String]) throws -> Exit {
        let a = try Args(args, options: ["--system", "--mic", "-o"], count: 0...2)
        if a.positional.isEmpty {
            guard let system = a["--system"], let mic = a["--mic"], let out = a["-o"] else {
                throw UsageError(message: "aec needs --system <file> --mic <file> -o <out>, or <recording-dir> [out]")
            }
            let output = URL(fileURLWithPath: out)
            try checkExtension(output, MicProcessor.outputExtensions)
            try runAEC(system: try inputFile(system), mic: try inputFile(mic), output: output)
            print(output.path)
            return .ok
        }
        guard a.values.isEmpty else {
            throw UsageError(message: "aec takes either <recording-dir> [out] or --system/--mic/-o, not both")
        }
        let dir = try recordingDir(a.positional[0])
        let meta = Finalizer.readMeta(dir)
        try checkNotBusy(dir, meta)
        let raw = Finalizer.rawDir(dir)
        let system = try? firstExisting(raw, [Finalizer.systemPCM, "system.caf"])
        let mic = try firstExisting(raw, [Finalizer.micPCM, "mic.caf"])
        // As recorded; a folder without session.json gets the defaults (echo cancellation + low NS).
        let options = meta.map {
            Finalizer.micOptions(meta: $0, echoMode: ($0["echo_cancellation"] as? String).flatMap(EchoMode.init) ?? .off,
                                 hasSystem: system != nil, hasMic: true)
        } ?? MicProcessor.Options(echoCancellation: system != nil)
        guard !options.summary.isEmpty else {
            let apple = (meta?["echo_cancellation"] as? String) == EchoMode.apple.rawValue
            printErr(apple ? "nothing to do: Apple voice processing already processed this recording's microphone"
                           : "nothing to do: echo cancellation, noise suppression and auto level are off for this recording")
            return .ok
        }
        if a.positional.count == 2 {
            let out = URL(fileURLWithPath: a.positional[1])
            try checkExtension(out, MicProcessor.outputExtensions)
            try runAEC(system: system, mic: mic, output: out, options: options)
            print(out.path)
            return .ok
        }
        // The recording's own layout: lossless PCM first, then AAC raw/mic_aec.caf.
        let pcm = raw.appendingPathComponent(Finalizer.micAECPCM)
        let out = raw.appendingPathComponent("mic_aec.caf")
        try runAEC(system: system, mic: mic, output: pcm, options: options)
        // The PCM goes either way: left behind, remix would prefer it over what session.json says.
        defer { try? FileManager.default.removeItem(at: pcm) }
        try Finalizer.writeAtomically(to: out) { temp in
            try Finalizer.encodeAAC(pcm, to: temp, bitRate: 64_000, progress: progress("encode"))
        }
        progressDone()
        if var meta {
            var tracks = meta["tracks"] as? [String: [String: Any]] ?? [:]
            tracks["mic_aec"] = ["file": "\(Finalizer.rawFolder)/mic_aec.caf", "duration_sec": Finalizer.duration(out),
                                 "format": "AAC 48kHz mono 64kbps, WebRTC " + options.summary]
            meta["tracks"] = tracks
            meta["mic_processing"] = options.summary
            if !Finalizer.writeMeta(meta, to: dir) { printErr("warning: could not update session.json") }
        }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("mixed.m4a").path) {
            printErr("mixed.m4a still has the previous microphone track: run remix to update it")
        }
        print(out.path)
        return .ok
    }

    /// A recording the app is (or will be) writing: still recording or saving, or left unfinished
    /// by a crash or quit, which the app finishes on its next launch.
    private static func checkNotBusy(_ dir: URL, _ meta: [String: Any]?) throws {
        guard let meta, let status = meta["status"] as? String, ["recording", "saving"].contains(status) else { return }
        let live = (meta["pid"] as? Int32).map { kill($0, 0) == 0 } ?? false
        throw Failure(description: live
            ? "\(dir.path) is still being recorded or saved (status \(status))"
            : "\(dir.path) is unfinished (status \(status)); open Meep to finish it first")
    }

    /// `remix <recording-dir> [--json] [-v]`: re-mix a recording's tracks into mixed.m4a and
    /// update session.json.
    static func remix(_ args: [String]) throws -> Exit {
        let a = try Args(args, flags: ["--json", "-v"], count: 1...1)
        let dir = try recordingDir(a.positional[0])
        let meta = Finalizer.readMeta(dir)
        try checkNotBusy(dir, meta)
        let raw = Finalizer.rawDir(dir)
        // Prefer lossless files (present if encoding failed or has not run yet), and the AEC mic.
        let system = try? firstExisting(raw, [Finalizer.systemPCM, "system.caf"])
        let mic = try? firstExisting(raw, [Finalizer.micAECPCM, "mic_aec.caf", Finalizer.micPCM, "mic.caf"])
        guard system != nil || mic != nil else { throw Failure(description: "no tracks found in \(raw.path)") }
        return try runMix(system: system, mic: mic, output: dir.appendingPathComponent("mixed.m4a"),
                          json: a.has("--json"), verbose: a.has("-v")) { r in
            guard var meta else { return }
            meta["mixed"] = "mixed.m4a"
            meta["mix_loudness_lufs"] = r.loudnessLUFS
            meta["mix_gain_db"] = r.gainsDB
            if !Finalizer.writeMeta(meta, to: dir) { printErr("warning: could not update session.json") }
        }
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
            printJSON(["output": output.path, "loudness_lufs": r.loudnessLUFS, "gain_db": r.gainsDB])
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
            throw Failure(description: "not a directory: \(path)")
        }
        return dir
    }

    static func inputFile(_ path: String) throws -> URL {
        guard FileManager.default.fileExists(atPath: path) else { throw Failure(description: "no such file: \(path)") }
        return URL(fileURLWithPath: path)
    }

    static func firstExisting(_ dir: URL, _ names: [String]) throws -> URL {
        guard let u = names.map({ dir.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw Failure(description: "none of \(names.joined(separator: ", ")) in \(dir.path)")
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

    static func printJSON(_ object: [String: Any]) {
        print(String(decoding: Finalizer.jsonData(object), as: UTF8.self))
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
