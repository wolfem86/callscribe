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

    public init(id: String, startDate: Date, isTest: Bool) {
        self.id = id
        self.startDate = startDate
        self.isTest = isTest
    }

    /// "Me only" when the call stream never captured anything.
    public var isMeOnly: Bool { !callCaptured }
}

public enum ManifestStore {
    public static let fileName = "session.json"

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
