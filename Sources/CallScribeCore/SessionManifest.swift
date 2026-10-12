import Foundation

/// session.json, written next to the WAV files and updated as the recording changes state.
/// Used for crash recovery now and for transcription and metadata in later phases.
public struct SessionManifest: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id: String
    public var startDate: Date
    public var endDate: Date?
    /// Wall-clock length in seconds, including pauses.
    public var wallDuration: Double?
    public var isTest: Bool
    public var finished = false
    public var recovered = false
    public var pauses = SpanList()
    /// Spans where the Others (call) stream wasn't capturing.
    public var callGaps = SpanList()
    public var callCaptured = false
    public var callSources: [String] = []
    public var micFile = "me.wav"
    public var callFile = "others.wav"
    /// Optional so session.json files written before transcription existed still decode.
    public var transcription: TranscriptionStatus?
    /// Pre-filled from the calendar (Phase 4); replaced by what the user confirms in the metadata dialog.
    public var meeting: MeetingMetadata?
    /// The user saved the metadata dialog (or it auto-saved). Transcripts are written only after this.
    public var metadataConfirmed: Bool?
    /// Teams call window title and names detected during the call, for pre-filling ad hoc calls.
    public var windowTitle: String?
    public var detectedParticipants: [String]?

    public static let transcriptCacheFile = "transcript.json"

    public init(id: String, startDate: Date, isTest: Bool) {
        self.id = id
        self.startDate = startDate
        self.isTest = isTest
    }

    /// "Me only" when the call stream never captured anything.
    public var isMeOnly: Bool { !callCaptured }
}

public struct TranscriptionStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// pending → transcribing → transcribed (waiting for the metadata dialog) → done (saved).
        case pending, transcribing, transcribed, done, failed
    }

    public var state: State
    public var error: String?
    /// Where the .md ended up (OneDrive, or the local outbox while OneDrive is unavailable).
    public var transcriptPath: String?
    public var savedLocally: Bool?
    public var updatedAt: Date

    public init(state: State, error: String? = nil, transcriptPath: String? = nil, savedLocally: Bool? = nil, updatedAt: Date = Date()) {
        self.state = state
        self.error = error
        self.transcriptPath = transcriptPath
        self.savedLocally = savedLocally
        self.updatedAt = updatedAt
    }
}

public enum ManifestStore {
    public static let fileName = "session.json"

    /// Finished, non-test sessions whose audio is still here, newest first.
    public static func allSessions(in root: URL) -> [(URL, SessionManifest)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return dirs.compactMap { dir in
            guard let manifest = try? load(from: dir), !manifest.isTest else { return nil }
            return (dir, manifest)
        }
        .sorted { $0.1.startDate > $1.1.startDate }
    }

    public static func save(_ manifest: SessionManifest, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    public static func load(from directory: URL) throws -> SessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionManifest.self, from: Data(contentsOf: directory.appendingPathComponent(fileName)))
    }

    /// Session folders under `root` that never finished (the app crashed or was killed mid-recording)
    /// and haven't been recovered yet.
    public static func unfinishedSessions(in root: URL, excluding activeID: String? = nil) -> [(URL, SessionManifest)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return dirs.compactMap { dir in
            guard let manifest = try? load(from: dir),
                  !manifest.finished, !manifest.recovered, !manifest.isTest,
                  manifest.id != activeID else { return nil }
            return (dir, manifest)
        }
        .sorted { $0.1.startDate < $1.1.startDate }
    }
}
