import Foundation

/// raw/session.json: one recording's metadata and status. Only the owner of the session's lock
/// (SessionLock) writes it: the app while recording and processing, or `remix` while it runs.
struct Session: Codable {
    enum Status: String, Codable {
        case recording, saving, complete, recovered, incomplete
        case recoveredAfterCrash = "recovered_after_crash"

        /// Capture or processing not finished: the app finishes it (on its next launch if needed).
        var isUnfinished: Bool { self == .recording || self == .saving }
        /// Saved with every track intact.
        var isOK: Bool { self == .complete || self == .recovered }
    }

    struct Interruption: Codable {
        let track: RecordingSession.Track
        let reason: String
        let detectedAtSec: Double
        var recoveredAtSec: Double?
        var attempts = 0
        var device: String?
        var lastError: String?
    }

    struct Track: Codable {
        var enabled: Bool?
        var peak: Float?
        var file: String?
        var durationSec: Double?
        var format: String?
        var note: String?
    }

    struct Tracks: Codable {
        var system = Track()
        var mic = Track()
        var micAec = Track()
    }

    /// Set once mic processing and the mix are done; a recovery from there only encodes.
    struct Processing: Codable {
        var stage = "encoding"
        var aec: Bool
    }

    var schemaVersion = 3
    var status: Status
    /// The status to set once processing is done (status is "saving" until then).
    var finalStatus: Status?
    var startedAt: Date
    var stoppedAt: Date?
    var durationSec: Double?
    var echoCancellation: EchoMode
    var systemAudio: Bool
    var microphone: Bool
    var noiseSuppression: NoiseSuppression
    var autoLevel: Bool
    var micVoiceProcessing = false
    var micDevice: String?
    var interruptions: [Interruption] = []
    var tracks = Tracks()
    var warnings: [String] = []
    var mixed: String?
    var mixLoudnessLufs: [String: Double]?
    var mixGainDb: [String: Double]?
    var micProcessing: String?
    var processing: Processing?
    var processingResumedAt: Date?

    static func url(_ dir: URL) -> URL { Finalizer.rawDir(dir).appendingPathComponent("session.json") }

    static func read(_ dir: URL) -> Session? { JSON.read(Session.self, from: url(dir)) }

    /// Returns false (and logs) if session.json could not be written, e.g. a full disk.
    @discardableResult
    func write(to dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: Finalizer.rawDir(dir), withIntermediateDirectories: true)
            try JSON.data(self).write(to: Self.url(dir), options: .atomic)
            return true
        } catch {
            NSLog("Meep: can't write %@: %@", Self.url(dir).path, "\(error)")
            return false
        }
    }

    mutating func setMix(_ r: Mixer.Result) {
        mixed = "mixed.m4a"
        mixLoudnessLufs = r.loudnessLUFS
        mixGainDb = r.gainsDB
    }

    /// Mic processing for this recording, from the settings stored at recording time. Apple voice
    /// processing already did its own noise suppression and gain.
    func micOptions(hasSystem: Bool, hasMic: Bool) -> MicProcessor.Options {
        let apple = echoCancellation == .apple && micVoiceProcessing
        return MicProcessor.Options(echoCancellation: echoCancellation == .webrtc && hasSystem && hasMic,
                                    noiseSuppression: apple ? .off : noiseSuppression,
                                    autoLevel: apple ? false : autoLevel)
    }
}

/// Exclusive owner of a recording folder: an flock(2) on raw/.lock. The kernel drops it when the
/// owner exits, also on a crash, so a held lock means a live owner (no pid that could be reused).
final class SessionLock: @unchecked Sendable {
    private var fd: Int32

    /// Takes the lock without waiting; nil if someone else (any process) holds it.
    init?(_ dir: URL) {
        let raw = Finalizer.rawDir(dir)
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let fd = open(raw.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        self.fd = fd
    }

    deinit { release() }

    func release() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// Whether a live process owns `dir`. Creates nothing.
    static func isHeld(_ dir: URL) -> Bool {
        let fd = open(Finalizer.rawDir(dir).appendingPathComponent(".lock").path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_SH | LOCK_NB) != 0
    }
}

/// The JSON files Meep writes: snake_case keys, ISO 8601 dates, pretty and key-sorted.
enum JSON {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func data<T: Encodable>(_ value: T) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(fractional.format(date))
        }
        return (try? e.encode(value)) ?? Data("{}".utf8)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = (try? fractional.parse(s)) ?? (try? plain.parse(s)) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(s)")
        }
        return try? d.decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try data(value).write(to: url, options: .atomic)
    }

    /// Prints `value` on stdout.
    static func print<T: Encodable>(_ value: T) {
        Swift.print(String(decoding: data(value), as: UTF8.self))
    }
}
