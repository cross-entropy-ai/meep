import Foundation

/// Runs the user's "Run After Saving" command once a recording is finished.
/// The command gets the recording folder as $1 and in $MEEP_DIR; it runs via `zsh -lc`
/// (reads ~/.zshenv and ~/.zprofile, not ~/.zshrc). Output goes to raw/after-save.log.
/// Its state is in raw/after-save.json (`State`), which only this hook writes: session.json has
/// other writers, and the command may still run while `remix` updates session.json.
enum AfterSaveHook {
    static let logName = "after-save.log"
    static let stateName = "after-save.json"

    struct State: Codable {
        enum Status: String, Codable { case running, done, failed }
        var command: String
        var status: Status
        var startedAt: Date
        var log: String
        var pid: Int32?
        var exitStatus: Int32?
        var finishedAt: Date?
        /// Why the command could not start.
        var error: String?
    }

    static func read(_ dir: URL) -> State? {
        JSON.read(State.self, from: Finalizer.rawDir(dir).appendingPathComponent(stateName))
    }

    /// The state of one run, written on every change. The termination handler runs on another thread.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var state: State
        private let url: URL

        init(_ state: State, url: URL) { self.state = state; self.url = url; write() }

        func update(_ change: (inout State) -> Void) {
            lock.lock(); defer { lock.unlock() }
            change(&state)
            write()
        }

        private func write() { try? JSON.write(state, to: url) }
    }

    static func run(_ dir: URL) {
        let cmd = AppSettings.afterSaveCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        let raw = Finalizer.rawDir(dir)
        let log = raw.appendingPathComponent(logName)
        FileManager.default.createFile(atPath: log.path, contents: Data("$ \(cmd) \(dir.path)\n".utf8))
        let out = try? FileHandle(forWritingTo: log)
        out?.seekToEndOfFile()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `cmd "$1"`: the command line as typed, with the folder as its first argument.
        p.arguments = ["-lc", "\(cmd) \"$1\"", "meep-after-save", dir.path]
        var env = ProcessInfo.processInfo.environment
        env["MEEP_DIR"] = dir.path
        p.environment = env
        p.currentDirectoryURL = dir
        p.standardInput = FileHandle.nullDevice  // not the app's or a terminal's stdin
        p.standardOutput = out
        p.standardError = out
        // Written before launch, so the "done" update can never be overwritten by "running".
        let state = Run(State(command: cmd, status: .running, startedAt: Date(), log: "\(Finalizer.rawFolder)/\(logName)"),
                        url: raw.appendingPathComponent(stateName))
        p.terminationHandler = { proc in
            out?.write(Data("\n[exit \(proc.terminationStatus)]\n".utf8))
            try? out?.close()
            // Killed by a signal: report it the way a shell does (128 + signal).
            let code = proc.terminationReason == .uncaughtSignal ? 128 + proc.terminationStatus : proc.terminationStatus
            state.update {
                $0.status = code == 0 ? .done : .failed
                $0.exitStatus = code
                $0.finishedAt = Date()
            }
        }
        do {
            try p.run()
            let pid = p.processIdentifier
            state.update { if $0.status == .running { $0.pid = pid } }
        } catch {
            out?.write(Data("failed to start: \(error)\n".utf8))
            try? out?.close()
            state.update {
                $0.status = .failed
                $0.error = "failed to start: \(error)"
                $0.finishedAt = Date()
            }
        }
    }
}
