import Foundation

/// A time span in seconds since the recording started (wall clock). `end == nil` means still open.
public struct TimeSpan: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double?

    public init(start: Double, end: Double? = nil) {
        self.start = start
        self.end = end
    }
}

/// An ordered list of non-overlapping spans: used for pauses and for gaps in the call stream.
public struct SpanList: Codable, Equatable, Sendable {
    public private(set) var spans: [TimeSpan]

    public init(spans: [TimeSpan] = []) {
        self.spans = spans
    }

    public var isOpen: Bool { spans.last.map { $0.end == nil } ?? false }

    public mutating func begin(at wall: Double) {
        guard !isOpen else { return }
        spans.append(TimeSpan(start: wall))
    }

    public mutating func end(at wall: Double) {
        guard isOpen else { return }
        spans[spans.count - 1].end = max(wall, spans[spans.count - 1].start)
    }

    /// Total span time between the recording start and `wall`. Open spans count up to `wall`.
    public func totalDuration(upTo wall: Double) -> Double {
        spans.reduce(0) { total, span in
            let start = min(span.start, wall)
            let end = min(span.end ?? wall, wall)
            return total + max(0, end - start)
        }
    }

    // MARK: Pause semantics

    /// Recording time that actually produced audio (wall time minus pauses).
    public func activeElapsed(atWall wall: Double) -> Double {
        max(0, wall - totalDuration(upTo: wall))
    }

    /// Maps a position in the audio file (pauses removed) back to wall-clock seconds since start.
    /// A position exactly at a pause boundary maps to the moment recording resumed.
    public func wallTime(forAudioTime audioTime: Double) -> Double {
        var pausedBefore = 0.0
        for span in spans {
            let audioAtPause = span.start - pausedBefore
            if audioTime < audioAtPause { return audioTime + pausedBefore }
            guard let end = span.end else { return audioTime + pausedBefore }
            pausedBefore += end - span.start
        }
        return audioTime + pausedBefore
    }
}
