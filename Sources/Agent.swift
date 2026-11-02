import Foundation

/// Runs the user's "Run After Saving" command once a recording is finished.
/// The command gets the recording folder as $1 and in $MEETINGRECORDER_DIR; it runs in a login
/// shell (so PATH matches the user's terminal). Output goes to raw/after-save.log.
/// Its state is recorded in session.json "after_save": {"command", "status": "running|done|failed",
/// "started_at", "log", "pid"}, plus "exit_status" and "finished_at" once it ends.
enum AfterSaveHook {
    static let logName = "after-save.log"
    private static let metaLock = NSLock()

    static func run(_ dir: URL) {
        let cmd = AppSettings.afterSaveCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        let log = Finalizer.rawDir(dir).appendingPathComponent(logName)
        FileManager.default.createFile(atPath: log.path, contents: Data("$ \(cmd) \(dir.path)\n".utf8))
        let out = try? FileHandle(forWritingTo: log)
        out?.seekToEndOfFile()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `cmd "$1"`: the command line as typed, with the folder as its first argument.
        p.arguments = ["-lc", "\(cmd) \"$1\"", "meetingrecorder-after-save", dir.path]
        var env = ProcessInfo.processInfo.environment
        env["MEETINGRECORDER_DIR"] = dir.path
        p.environment = env
        p.currentDirectoryURL = dir
        p.standardOutput = out
        p.standardError = out
        p.terminationHandler = { proc in
            out?.write(Data("\n[exit \(proc.terminationStatus)]\n".utf8))
            try? out?.close()
            // Killed by a signal: report it the way a shell does (128 + signal).
            let code = proc.terminationReason == .uncaughtSignal ? 128 + proc.terminationStatus : proc.terminationStatus
            AfterSaveHook.update(dir) {
                $0["status"] = code == 0 ? "done" : "failed"
                $0["exit_status"] = code
                $0["finished_at"] = AfterSaveHook.now()
            }
        }
        // Recorded before launch, so the "done" update can never be overwritten by "running".
        update(dir) {
            $0 = ["command": cmd, "status": "running", "started_at": now(),
                  "log": "\(Finalizer.rawFolder)/\(logName)"]
        }
        do {
            try p.run()
            let pid = p.processIdentifier
            update(dir) { if $0["status"] as? String == "running" { $0["pid"] = pid } }
        } catch {
            out?.write(Data("failed to start: \(error)\n".utf8))
            try? out?.close()
            update(dir) {
                $0["status"] = "failed"
                $0["exit_status"] = NSNull()
                $0["error"] = "failed to start: \(error)"
                $0["finished_at"] = now()
            }
        }
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    /// Read-modify-write of session.json "after_save" (writeMeta replaces the file atomically).
    private static func update(_ dir: URL, _ change: (inout [String: Any]) -> Void) {
        metaLock.lock(); defer { metaLock.unlock() }
        guard var meta = Finalizer.readMeta(dir) else { return }
        var state = meta["after_save"] as? [String: Any] ?? [:]
        change(&state)
        meta["after_save"] = state
        Finalizer.writeMeta(meta, to: dir)
    }
}

/// `MeetingRecorder --status`: machine-readable state for agents, derived from the recordings
/// on disk (no connection to the running app needed).
enum StatusReport {
    static func json() -> String {
        let root = RecordingSession.rootDirectory
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { Finalizer.readMeta($0) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }  // names are timestamps

        var current: [String: Any]?
        var latest: [String: Any]?
        for dir in dirs {
            guard let meta = Finalizer.readMeta(dir) else { continue }
            let status = meta["status"] as? String ?? ""
            let live = (meta["pid"] as? Int32).map { kill($0, 0) == 0 } ?? false
            if current == nil, status == "recording" || status == "saving", live {
                current = ["state": status, "dir": dir.path, "started_at": meta["started_at"] ?? NSNull()]
            } else if latest == nil, status != "recording", status != "saving" {
                let mixed = dir.appendingPathComponent("mixed.m4a")
                latest = [
                    "dir": dir.path,
                    "mixed": FileManager.default.fileExists(atPath: mixed.path) ? mixed.path : NSNull(),
                    "status": status,
                    "started_at": meta["started_at"] ?? NSNull(),
                    "duration_sec": meta["duration_sec"] ?? NSNull(),
                    "after_save": meta["after_save"] ?? NSNull(),
                ]
            }
            if current != nil && latest != nil { break }
        }
        let report: [String: Any] = [
            "state": current?["state"] ?? "idle",
            "current": current ?? NSNull(),
            "latest": latest ?? NSNull(),
            "recordings_folder": root.path,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

enum HelpText {
    static var text: String {
        let exe = Bundle.main.executableURL?.path ?? "MeetingRecorder"
        return """
        MeetingRecorder — records system audio + microphone for meetings.

        CONTROL (the app must be installed; these launch it if needed)
          open "meetingrecorder://start"         start recording
          open "meetingrecorder://stop"          stop recording and save
          open "meetingrecorder://preferences"   open Preferences

        COMMANDS
          \(exe) --status
              JSON: {"state": "idle|recording|saving", "current": {...}, "latest": {"dir", "mixed", ...}}.
              Poll it after "stop" until state is "idle" to know the recording is saved.
          \(exe) --aec <recording-dir> [out.caf]
              Re-run WebRTC echo cancellation → raw/mic_aec.caf
          \(exe) --remix <recording-dir>
              Re-mix the tracks → mixed.m4a
          \(exe) --login-item on|off|status
              Start at Login
          \(exe) --help

        OUTPUT  \(RecordingSession.rootDirectory.path)/<yyyy-MM-dd_HHmmss>/
          mixed.m4a          system audio + microphone, loudness-matched
          raw/system.caf     what the Mac played (other participants)
          raw/mic.caf        microphone (you)
          raw/mic_aec.caf    microphone with speaker echo removed (WebRTC mode)
          raw/session.json   status, timing, interruptions, warnings
          All tracks start at the same moment: sample N of every file is the same instant.

        AFTER SAVING
          Preferences › Agent › Run After Saving: a shell command run after each recording is saved,
          with the recording folder as $1 and $MEETINGRECORDER_DIR. Output: raw/after-save.log.
        """
    }
}
