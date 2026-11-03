import Foundation

/// `meep status`: state derived from the recordings on disk (no connection to the running app
/// needed). `start/stop --wait` poll the same state. A recording is live while its owner holds
/// its SessionLock.
struct StatusReport: Encodable {
    enum State: String, Encodable { case idle, recording, saving }

    struct Current: Encodable {
        var state: State
        var dir: String
        var startedAt: Date
    }

    struct Latest: Encodable {
        var dir: String
        var mixed: String?
        var status: Session.Status
        var startedAt: Date
        var durationSec: Double?
        var afterSave: AfterSaveHook.State?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(dir, forKey: .dir)
            try c.encode(mixed, forKey: .mixed)  // null, not left out: keys stay stable for scripts
            try c.encode(status, forKey: .status)
            try c.encode(startedAt, forKey: .startedAt)
            try c.encode(durationSec, forKey: .durationSec)
            try c.encode(afterSave, forKey: .afterSave)
        }
        private enum CodingKeys: CodingKey { case dir, mixed, status, startedAt, durationSec, afterSave }
    }

    var state: State
    var current: Current?
    var latest: Latest?
    var recordingsFolder: String

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encode(current, forKey: .current)
        try c.encode(latest, forKey: .latest)
        try c.encode(recordingsFolder, forKey: .recordingsFolder)
    }
    private enum CodingKeys: CodingKey { case state, current, latest, recordingsFolder }

    static func report() -> StatusReport {
        let root = RecordingSession.rootDirectory
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }  // names are timestamps

        var current: Current?
        var latest: Latest?
        for dir in dirs {
            guard let s = Session.read(dir) else { continue }
            if s.status.isUnfinished {
                if current == nil, SessionLock.isHeld(dir) {
                    current = Current(state: s.status == .recording ? .recording : .saving,
                                      dir: dir.path, startedAt: s.startedAt)
                }
            } else if latest == nil {
                let mixed = dir.appendingPathComponent("mixed.m4a")
                latest = Latest(dir: dir.path,
                                mixed: FileManager.default.fileExists(atPath: mixed.path) ? mixed.path : nil,
                                status: s.status, startedAt: s.startedAt, durationSec: s.durationSec,
                                afterSave: AfterSaveHook.read(dir))
            }
            if current != nil && latest != nil { break }
        }
        return StatusReport(state: current?.state ?? .idle, current: current, latest: latest,
                            recordingsFolder: root.path)
    }

    /// The live recording (state "recording" or "saving"), if any.
    static var current: Current? { report().current }
}

/// Why the last start failed, for `start --wait` (a failed start leaves no recording folder).
/// ~/Library/Application Support/Meep/last-start.json: {"at": ISO 8601, "error": text}.
enum StartFailure {
    private struct Record: Codable { var at: Date; var error: String }

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Meep/last-start.json")
    }

    static func record(_ error: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSON.write(Record(at: Date(), error: error), to: url)
    }

    /// The error of a start that failed at or after `date`, if any.
    static func since(_ date: Date) -> String? {
        guard let r = JSON.read(Record.self, from: url), r.at >= date else { return nil }
        return r.error
    }
}
