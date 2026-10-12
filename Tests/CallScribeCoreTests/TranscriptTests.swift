import Foundation
import Testing
@testable import CallScribeCore

private let utc = TimeZone(identifier: "UTC")!
private let us = Locale(identifier: "en_US_POSIX")
private let start = Date(timeIntervalSince1970: 1_791_710_400)  // 2026-10-11 09:20:00 UTC (Sunday)

private func meeting() -> MeetingMetadata {
    MeetingMetadata(title: "Ad hoc call", recordedStart: start, recordedEnd: start.addingTimeInterval(600))
}

@Suite struct TranscriptBuilderTests {
    @Test func mergesStreamsInTimeOrderAndMapsPauses() {
        var pauses = SpanList()
        pauses.begin(at: 20); pauses.end(at: 50)  // 30 s pause
        let me = [TranscriptSegment(speaker: .me, start: 5, end: 8, text: "Hello there."),
                  TranscriptSegment(speaker: .me, start: 25, end: 27, text: "After the pause.")]
        let others = [TranscriptSegment(speaker: .others, start: 9, end: 12, text: "Hi, how are you?")]
        let doc = TranscriptBuilder.build(meeting: meeting(), me: me, others: others, pauses: pauses,
                                          callGaps: SpanList(), callCaptured: true, callSources: ["com.microsoft.teams2"])
        #expect(doc.segments.map(\.text) == ["Hello there.", "Hi, how are you?", "After the pause."])
        #expect(doc.segments[2].start == 55)  // audio 25 s → wall 55 s
        #expect(doc.pauses == [TimeSpan(start: 20, end: 50)])

        let md = TranscriptBuilder.markdown(doc, locale: us, timeZone: utc).replacingOccurrences(of: "\u{202F}", with: " ")
        #expect(md.contains("[00:00:05] Me: Hello there."))
        #expect(md.contains("[00:00:09] Others: Hi, how are you?"))
        #expect(md.contains("[Paused 00:00:20–00:00:50]"))
        let pauseIndex = md.range(of: "[Paused")!.lowerBound
        #expect(md.range(of: "Others: Hi")!.lowerBound < pauseIndex)
        #expect(pauseIndex < md.range(of: "After the pause")!.lowerBound)
    }

    @Test func leakedMeCopyIsDroppedAndRecorded() {
        let me = [TranscriptSegment(speaker: .me, start: 49.6, end: 56, text: "phone test alpha bravo charlie")]
        let others = [TranscriptSegment(speaker: .others, start: 49.5, end: 56, text: "Phone test. Alpha, bravo, charlie.")]
        let doc = TranscriptBuilder.build(meeting: meeting(), me: me, others: others, pauses: SpanList(),
                                          callGaps: SpanList(), callCaptured: true, callSources: [])
        #expect(doc.segments.map(\.speaker) == [.others])
        #expect(doc.droppedDuplicates.count == 1)
    }

    @Test func headerOmitsEmptyLinesAndFlagsMeOnly() {
        let doc = TranscriptBuilder.build(meeting: meeting(), me: [TranscriptSegment(speaker: .me, start: 1, end: 2, text: "Testing.")],
                                          others: [], pauses: SpanList(), callGaps: SpanList(), callCaptured: false, callSources: [])
        let md = TranscriptBuilder.markdown(doc, locale: us, timeZone: utc).replacingOccurrences(of: "\u{202F}", with: " ")
        #expect(md.hasPrefix("# Ad hoc call\n"))
        #expect(md.contains("**Date:** Sunday, October 11, 2026 · **Recorded:** 9:20 AM–9:30 AM"))
        #expect(!md.contains("Scheduled"))
        #expect(!md.contains("Organizer"))
        #expect(!md.contains("Tags"))
        #expect(md.contains("**Capture:** Me only"))
        #expect(md.contains("\n---\n"))
    }

    @Test func fullCalendarHeader() {
        var m = meeting()
        m.title = "Weekly sync"
        m.scheduledStart = start.addingTimeInterval(-120)
        m.scheduledEnd = start.addingTimeInterval(1680)
        m.organizer = Person(name: "Jane Smith", email: "jane@contoso.com")
        m.invited = [Person(name: "Bo Li", email: "bo@contoso.com", rsvp: "Accepted")]
        m.participants = ["Ignored when invited exists"]
        m.location = "https://teams.microsoft.com/l/meetup-join/abc"
        m.agenda = "Roadmap\nBudget"
        m.tags = ["planning", "q4"]
        m.notes = "Follow up on budget"
        let doc = TranscriptBuilder.build(meeting: m, me: [], others: [], pauses: SpanList(),
                                          callGaps: SpanList(), callCaptured: true, callSources: [])
        let md = TranscriptBuilder.markdown(doc, locale: us, timeZone: utc).replacingOccurrences(of: "\u{202F}", with: " ")
        #expect(md.contains("**Scheduled:** 9:18 AM–9:48 AM · **Recorded:** 9:20 AM–9:30 AM"))
        #expect(md.contains("**Organizer:** Jane Smith (jane@contoso.com)"))
        #expect(md.contains("**Invited:** Bo Li (bo@contoso.com) – Accepted"))
        #expect(!md.contains("Participants (detected)"))
        #expect(md.contains("**Agenda:** Roadmap Budget"))
        #expect(md.contains("**Tags:** planning, q4"))
        #expect(md.contains("_No speech was detected._"))
    }

    @Test func reportsOnlyMeaningfulCallGaps() {
        var gaps = SpanList()
        gaps.begin(at: 0); gaps.end(at: 1.5)      // startup: ignored
        gaps.begin(at: 100); gaps.end(at: 160)    // real gap
        var pauses = SpanList()
        pauses.begin(at: 300); pauses.end(at: 400)
        gaps.begin(at: 299); gaps.end(at: 402)    // mostly a pause: ignored
        let doc = TranscriptBuilder.build(meeting: meeting(), me: [], others: [], pauses: pauses,
                                          callGaps: gaps, callCaptured: true, callSources: [])
        #expect(doc.capture.callGaps == [TimeSpan(start: 100, end: 160)])
        #expect(TranscriptBuilder.markdown(doc).contains("Others missing 00:01:40–00:02:40"))
    }

    @Test func cleanerStripsTokensAndRepeats() {
        let segments = [
            TranscriptSegment(speaker: .others, start: 0, end: 2, text: "<|startoftranscript|> Hello."),
            TranscriptSegment(speaker: .others, start: 2, end: 4, text: "Hello"),
            TranscriptSegment(speaker: .others, start: 4, end: 5, text: "  "),
            TranscriptSegment(speaker: .others, start: 5, end: 7, text: "Goodbye."),
        ]
        let result = SegmentCleaner.clean(segments)
        #expect(result.kept.map(\.text) == ["Hello.", "Goodbye."])
        #expect(result.removedRepeats == 1)
    }

    @Test func jsonRoundTrip() throws {
        let doc = TranscriptBuilder.build(meeting: meeting(), me: [TranscriptSegment(speaker: .me, start: 1, end: 2, text: "Hi", confidence: 0.9)],
                                          others: [], pauses: SpanList(), callGaps: SpanList(), callCaptured: true, callSources: [])
        let decoded = try TranscriptDocument.decode(try doc.jsonData())
        #expect(decoded == doc)
        let json = String(decoding: try doc.jsonData(), as: UTF8.self)
        #expect(json.contains("\"meeting\""))
        #expect(json.contains("\"confidence\""))
    }
}

@Suite struct FileNamingTests {
    @Test func sanitizesTitles() {
        #expect(FileNaming.sanitizedTitle("Q4: Plan / Review?") == "Q4 Plan Review")
        #expect(FileNaming.sanitizedTitle("  ...Hidden.  ") == "Hidden")
        #expect(FileNaming.sanitizedTitle("***") == "Ad hoc call")
        #expect(FileNaming.sanitizedTitle(String(repeating: "a", count: 120)).count == 80)
    }

    @Test func baseNameFormat() {
        #expect(FileNaming.baseName(title: "Weekly sync", date: start, timeZone: utc) == "Weekly sync - 2026-10-11 0920")
    }

    @Test func uniqueNamesAppendCounter() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/A.md", "/tmp/x/A (2).md"]
        let url = FileNaming.uniqueURL(in: dir, base: "A", ext: "md") { taken.contains($0.path) }
        #expect(url.lastPathComponent == "A (3).md")
    }

    @Test func findsOneDriveFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString)")
        for name in ["OneDrive-Personal", "OneDrive-Contoso", "GoogleDrive-me"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let candidates = OneDriveLocator.candidates(in: root)
        #expect(candidates.map(\.lastPathComponent) == ["OneDrive-Contoso", "OneDrive-Personal"])
        #expect(OneDriveLocator.preferred(candidates)?.lastPathComponent == "OneDrive-Contoso")
        #expect(OneDriveLocator.candidates(in: root.appendingPathComponent("missing")).isEmpty)
    }
}
