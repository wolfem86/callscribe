import Foundation

/// Cleans per-stream Whisper output before merging.
public enum SegmentCleaner {
    /// Removes special tokens, blank segments, and immediate repeats (a common Whisper failure on noise).
    public static func clean(_ segments: [TranscriptSegment]) -> (kept: [TranscriptSegment], removedRepeats: Int) {
        var kept: [TranscriptSegment] = []
        var repeats = 0
        for var segment in segments.sorted(by: { $0.start < $1.start }) {
            segment.text = stripSpecialTokens(segment.text)
            guard !DuplicateGuard.normalize(segment.text).isEmpty else { continue }
            if let last = kept.last,
               DuplicateGuard.normalize(last.text) == DuplicateGuard.normalize(segment.text),
               segment.start - last.end < 5 {
                repeats += 1
                continue
            }
            kept.append(segment)
        }
        return (kept, repeats)
    }

    static func stripSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Merges both streams into one document and renders the Markdown transcript.
public enum TranscriptBuilder {
    /// - Parameters:
    ///   - me, others: segments with times in each stream's audio time (pauses removed).
    ///   - pauses: wall-clock pauses, used to map audio time back to time since the recording started.
    public static func build(meeting: MeetingMetadata,
                             me: [TranscriptSegment],
                             others: [TranscriptSegment],
                             pauses: SpanList,
                             callGaps: SpanList,
                             callCaptured: Bool,
                             callSources: [String]) -> TranscriptDocument {
        let toWall = { (segment: TranscriptSegment) -> TranscriptSegment in
            var mapped = segment
            mapped.start = pauses.wallTime(forAudioTime: segment.start)
            mapped.end = max(mapped.start, pauses.wallTime(forAudioTime: segment.end))
            return mapped
        }
        let merged = SegmentCleaner.clean(me).kept.map(toWall) + SegmentCleaner.clean(others).kept.map(toWall)
        let guarded = DuplicateGuard.apply(merged.sorted { $0.start < $1.start })

        let pauseSpans = pauses.spans.compactMap { span in span.end.map { TimeSpan(start: span.start, end: $0) } }
        let gaps = callCaptured ? meaningfulGaps(callGaps, pauses: pauseSpans) : []

        return TranscriptDocument(
            meeting: meeting,
            capture: CaptureInfo(meOnly: !callCaptured, callGaps: gaps, callSources: callSources),
            segments: guarded.kept,
            pauses: pauseSpans,
            droppedDuplicates: guarded.dropped.map {
                DroppedDuplicateRecord(start: $0.dropped.start, end: $0.dropped.end, text: $0.dropped.text,
                                       matchedOthersText: $0.matchedText, similarity: $0.similarity)
            }
        )
    }

    /// Call-stream gaps worth reporting: longer than 5 s and not just a pause or the tap starting up.
    static func meaningfulGaps(_ gaps: SpanList, pauses: [TimeSpan]) -> [TimeSpan] {
        gaps.spans.compactMap { gap in
            guard let end = gap.end else { return nil }
            let paused = pauses.reduce(0.0) { total, pause in
                total + max(0, min(end, pause.end ?? end) - max(gap.start, pause.start))
            }
            return (end - gap.start - paused) > 5 ? TimeSpan(start: gap.start, end: end) : nil
        }
    }

    // MARK: Markdown

    public static func markdown(_ document: TranscriptDocument,
                                locale: Locale = .current,
                                timeZone: TimeZone = .current) -> String {
        let meeting = document.meeting
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = timeZone
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .none
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.timeZone = timeZone
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        var header: [String] = []
        var dateLine = "**Date:** \(dateFormatter.string(from: meeting.scheduledStart ?? meeting.recordedStart))"
        if let start = meeting.scheduledStart, let end = meeting.scheduledEnd {
            dateLine += " · **Scheduled:** \(timeFormatter.string(from: start))–\(timeFormatter.string(from: end))"
        }
        dateLine += " · **Recorded:** \(timeFormatter.string(from: meeting.recordedStart))–\(timeFormatter.string(from: meeting.recordedEnd))"
        header.append(dateLine)

        if let organizer = meeting.organizer, !organizer.display.isEmpty {
            header.append("**Organizer:** \(organizer.display)")
        }
        if !meeting.invited.isEmpty {
            let invited = meeting.invited.map { person in
                person.rsvp.map { "\(person.display) – \($0)" } ?? person.display
            }
            header.append("**Invited:** \(invited.joined(separator: ", "))")
        } else if !meeting.participants.isEmpty {
            header.append("**Participants (detected):** \(meeting.participants.joined(separator: ", "))")
        }
        if let location = nonEmpty(meeting.location) { header.append("**Location / link:** \(location)") }
        if let agenda = nonEmpty(meeting.agenda) { header.append("**Agenda:** \(agenda)") }
        if !meeting.tags.isEmpty { header.append("**Tags:** \(meeting.tags.joined(separator: ", "))") }
        if let notes = nonEmpty(meeting.notes) { header.append("**Notes:** \(notes)") }
        if document.capture.meOnly {
            header.append("**Capture:** Me only — Teams audio wasn't captured, so other participants are missing.")
        } else if !document.capture.callGaps.isEmpty {
            let gaps = document.capture.callGaps.map { "\(timestamp($0.start))–\(timestamp($0.end ?? $0.start))" }
            header.append("**Capture:** Others missing \(gaps.joined(separator: ", "))")
        }

        // Transcript lines and pause markers in time order.
        var body: [(Double, String)] = document.segments.map {
            ($0.start, "[\(timestamp($0.start))] \($0.speaker.rawValue): \($0.text)")
        }
        body += document.pauses.map { ($0.start, "[Paused \(timestamp($0.start))–\(timestamp($0.end ?? $0.start))]") }
        body.sort { $0.0 < $1.0 }

        var lines = ["# \(meeting.title)", ""]
        // Blank lines keep each header field on its own line in Markdown.
        lines += header.flatMap { [$0, ""] }
        lines.append("---")
        lines.append("")
        if body.isEmpty {
            lines.append("_No speech was detected._")
        } else {
            lines += body.flatMap { [$0.1, ""] }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// HH:MM:SS from seconds since the recording started.
    public static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }
}
