import Foundation

public struct Person: Codable, Equatable, Sendable {
    public var name: String
    public var email: String?
    /// Calendar response, e.g. "Accepted", "Tentative".
    public var rsvp: String?

    public init(name: String, email: String? = nil, rsvp: String? = nil) {
        self.name = name
        self.email = email
        self.rsvp = rsvp
    }

    /// "Jane Smith (jane@contoso.com)", or whichever parts exist.
    public var display: String {
        switch (name.isEmpty, email?.isEmpty ?? true) {
        case (false, false): return "\(name) (\(email!))"
        case (true, false): return email!
        default: return name
        }
    }
}

/// Everything the transcript header shows. Filled from the calendar or detection,
/// then confirmed in the metadata dialog (Phase 3).
public struct MeetingMetadata: Codable, Equatable, Sendable {
    public var title: String
    public var recordedStart: Date
    public var recordedEnd: Date
    public var scheduledStart: Date?
    public var scheduledEnd: Date?
    public var organizer: Person?
    public var invited: [Person] = []
    /// Detected names for ad hoc calls (e.g. from the Teams window title).
    public var participants: [String] = []
    public var location: String?
    public var agenda: String?
    public var tags: [String] = []
    public var notes: String?

    public init(title: String, recordedStart: Date, recordedEnd: Date) {
        self.title = title
        self.recordedStart = recordedStart
        self.recordedEnd = recordedEnd
    }
}

public struct CaptureInfo: Codable, Equatable, Sendable {
    /// The call stream never captured anything.
    public var meOnly: Bool
    /// Spans (seconds from recording start) where the call stream wasn't capturing, excluding pauses and startup.
    public var callGaps: [TimeSpan]
    public var callSources: [String]

    public init(meOnly: Bool, callGaps: [TimeSpan], callSources: [String]) {
        self.meOnly = meOnly
        self.callGaps = callGaps
        self.callSources = callSources
    }
}

public struct DroppedDuplicateRecord: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var matchedOthersText: String
    public var similarity: Double
}

/// The .json saved next to every transcript. Segment times are seconds from the recording start (wall clock).
public struct TranscriptDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var meeting: MeetingMetadata
    public var capture: CaptureInfo
    public var segments: [TranscriptSegment]
    public var pauses: [TimeSpan]
    public var droppedDuplicates: [DroppedDuplicateRecord]

    public init(meeting: MeetingMetadata, capture: CaptureInfo, segments: [TranscriptSegment],
                pauses: [TimeSpan], droppedDuplicates: [DroppedDuplicateRecord]) {
        self.meeting = meeting
        self.capture = capture
        self.segments = segments
        self.pauses = pauses
        self.droppedDuplicates = droppedDuplicates
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> TranscriptDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptDocument.self, from: data)
    }
}
