import Foundation
import Testing
@testable import CallScribeCore

private let teamsBody = """
<html><body><p>Agenda:</p><ul><li>Roadmap &amp; budget</li><li>Hiring</li></ul>
<div>________________________________________________________________________________</div>
<div>Microsoft Teams meeting</div><div>Join on your computer, mobile app or room device</div>
<a href="https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d">Click here to join the meeting</a>
</body></html>
"""

@Suite struct PowerAutomateCalendarTests {
    /// The shape "Get calendar view of events (V3)" produces.
    @Test func parsesV3Output() throws {
        let json: [[String: Any]] = [[
            "id": "AAMk1", "subject": "Weekly sync",
            "start": "2026-10-19T14:00:00.0000000", "end": "2026-10-19T14:30:00.0000000",
            "startWithTimeZone": "2026-10-19T14:00:00+00:00", "endWithTimeZone": "2026-10-19T14:30:00+00:00",
            "body": teamsBody, "isHtml": true, "organizer": "jane.smith@contoso.com",
            "requiredAttendees": "jane.smith@contoso.com;bo.li@contoso.com;", "optionalAttendees": "ana@contoso.com;",
            "location": "Microsoft Teams Meeting", "isAllDay": false,
        ]]
        let result = try PowerAutomateCalendar.parse(JSONSerialization.data(withJSONObject: json))
        let event = try #require(result.events.first)
        #expect(event.title == "Weekly sync")
        #expect(event.start == Date(timeIntervalSince1970: 1_792_418_400))
        #expect(event.end.timeIntervalSince(event.start) == 1_800)
        #expect(event.organizer == Person(name: "Jane Smith", email: "jane.smith@contoso.com"))
        #expect(event.attendees.map(\.display) == ["Bo Li (bo.li@contoso.com)", "ana@contoso.com"])
        #expect(event.joinURL?.hasPrefix("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc") == true)
        #expect(event.agenda == "Agenda:\nRoadmap & budget\nHiring")
        #expect(result.fieldsSeen.contains("subject"))
    }

    @Test func parsesGraphShapeInsideValue() throws {
        let json: [String: Any] = ["value": [[
            "id": "g1", "subject": "1:1",
            "start": ["dateTime": "2026-10-19T09:00:00.0000000", "timeZone": "UTC"],
            "end": ["dateTime": "2026-10-19T09:30:00.0000000", "timeZone": "UTC"],
            "organizer": ["emailAddress": ["name": "Jane Smith", "address": "jane@contoso.com"]],
            "attendees": [["emailAddress": ["name": "Bo Li", "address": "bo@contoso.com"], "status": ["response": "accepted"]]],
            "onlineMeeting": ["joinUrl": "https://teams.microsoft.com/l/meetup-join/xyz"],
            "body": ["contentType": "text", "content": "Quick catch-up"],
        ]]]
        let event = try #require(try PowerAutomateCalendar.parse(JSONSerialization.data(withJSONObject: json)).events.first)
        #expect(event.attendees == [Person(name: "Bo Li", email: "bo@contoso.com", rsvp: "Accepted")])
        #expect(event.joinURL == "https://teams.microsoft.com/l/meetup-join/xyz")
        #expect(event.agenda == "Quick catch-up")
    }

    @Test func skipsEventsWithoutTimesAndRejectsNonLists() throws {
        let json: [[String: Any]] = [["subject": "No times"]]
        #expect(try PowerAutomateCalendar.parse(JSONSerialization.data(withJSONObject: json)).skipped == 1)
        #expect(throws: (any Error).self) { try PowerAutomateCalendar.parse(Data("{\"a\":1}".utf8)) }
    }

    @Test func eventBecomesPrefilledMeeting() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let event = CalendarEvent(id: "1", title: "Weekly sync", start: start, end: start.addingTimeInterval(1_800),
                                  organizer: Person(name: "Jane"), attendees: [Person(name: "Bo")],
                                  location: "Room 1", joinURL: "https://teams.microsoft.com/l/meetup-join/x", agenda: "Plan")
        let meeting = event.meeting(recordedStart: start.addingTimeInterval(60), recordedEnd: start.addingTimeInterval(1_700))
        #expect(meeting.title == "Weekly sync")
        #expect(meeting.scheduledStart == start)
        #expect(meeting.invited == [Person(name: "Bo")])
        #expect(meeting.location == "https://teams.microsoft.com/l/meetup-join/x")
        #expect(meeting.agenda == "Plan")
    }
}

@Suite struct EventMatcherTests {
    let base = Date(timeIntervalSince1970: 2_000_000)

    func event(_ id: String, startMinutes: Double, minutes: Double = 30, teams: Bool = true, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: base.addingTimeInterval(startMinutes * 60),
                      end: base.addingTimeInterval((startMinutes + minutes) * 60),
                      joinURL: teams ? "https://teams.microsoft.com/l/meetup-join/\(id)" : nil, isAllDay: allDay)
    }

    @Test func picksOverlappingOrNearbyTeamsMeeting() {
        let events = [event("lunch", startMinutes: -5, teams: false), event("sync", startMinutes: 2),
                      event("allday", startMinutes: -600, minutes: 1_440, allDay: true), event("later", startMinutes: 60)]
        #expect(EventMatcher.match(events, recordingStart: base)?.id == "sync")
        #expect(EventMatcher.match([event("ongoing", startMinutes: -25)], recordingStart: base)?.id == "ongoing")
        #expect(EventMatcher.match([event("far", startMinutes: 20)], recordingStart: base) == nil)
        #expect(EventMatcher.match([event("allday", startMinutes: -600, minutes: 1_440, allDay: true)], recordingStart: base) == nil)
    }

    @Test func prefersClosestStart() {
        let events = [event("a", startMinutes: -14), event("b", startMinutes: 1)]
        #expect(EventMatcher.match(events, recordingStart: base)?.id == "b")
    }
}

@Suite struct AgendaAndNamesTests {
    @Test func agendaWithoutBoilerplate() {
        #expect(AgendaCleaner.agenda("Microsoft Teams meeting\nJoin on your computer") == nil)
        #expect(AgendaCleaner.agenda("  Topics  \n\n\n\nBudget\n____\nMicrosoft Teams meeting") == "Topics\n\nBudget")
    }

    @Test func namesFromEmail() {
        #expect(NameFromEmail.guess("jane.smith@contoso.com") == "Jane Smith")
        #expect(NameFromEmail.guess("bo_li2@contoso.com") == "Bo Li2")
        #expect(NameFromEmail.guess("ana@contoso.com") == "")
    }
}

@Suite struct TeamsWindowTitleTests {
    @Test func meetingNamesFromTitles() {
        #expect(TeamsWindowTitle.meetingName(from: "Weekly sync | Microsoft Teams") == "Weekly sync")
        #expect(TeamsWindowTitle.meetingName(from: "Chat | Jane Smith | Contoso | me@contoso.com | Microsoft Teams") == nil)
        #expect(TeamsWindowTitle.meetingName(from: "Calendar | Contoso | me@contoso.com | Microsoft Teams") == nil)
        #expect(TeamsWindowTitle.meetingName(from: "Microsoft Teams") == nil)
        #expect(TeamsWindowTitle.bestMeetingName(from: ["Chat | X | a@b.com | Microsoft Teams", "Call with Jane Smith | Microsoft Teams"]) == "Call with Jane Smith")
    }

    @Test func participantsFromCallNames() {
        #expect(TeamsWindowTitle.participants(fromMeetingName: "Call with Jane Smith") == ["Jane Smith"])
        #expect(TeamsWindowTitle.participants(fromMeetingName: "Meeting with Jane Smith and Bo Li") == ["Jane Smith", "Bo Li"])
        #expect(TeamsWindowTitle.participants(fromMeetingName: "Weekly sync").isEmpty)
    }
}
